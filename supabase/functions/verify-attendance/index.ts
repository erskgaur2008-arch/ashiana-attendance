// verify-attendance — staff login bridge, PIN change, QR attendance.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
const corsHeaders = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json","Cache-Control":"no-store"}});
const PER_STAFF_MAX=6, PER_STAFF_WINDOW=900, PER_IP_MAX=60, PER_IP_WINDOW=600;
const SCHOOL_GEOFENCE_LAT=30.704607009887695;
const SCHOOL_GEOFENCE_LON=76.76773834228516;
const GEOFENCE_RADIUS_METERS=50;
const MAX_LOCATION_ACCURACY_METERS=25;
const MAX_LOCATION_AGE_MS=120_000;
async function sha256Hex(value:string){const bytes=new TextEncoder().encode(value);const digest=await crypto.subtle.digest("SHA-256",bytes);return Array.from(new Uint8Array(digest),(b)=>b.toString(16).padStart(2,"0")).join("");}
function clientIp(req:Request){const h=req.headers;const direct=h.get("cf-connecting-ip")||h.get("x-real-ip");if(direct)return direct.trim();const xff=(h.get("x-forwarded-for")||"").split(",").map(s=>s.trim()).filter(Boolean);return xff.length?xff[xff.length-1]:"unknown";}
const escapeLike=(v:string)=>v.replace(/[\\%_]/g,c=> "\\"+c);
const randomSecret=()=>{const lower=crypto.randomUUID().replace(/-/g,"");const upper=crypto.randomUUID().replace(/-/g,"").toUpperCase().slice(0,16);return `Aa1!${lower}${upper}`;};
function isExpired(validThru?:string|null){if(!validThru)return false;const today=new Date().toISOString().slice(0,10);return new Date(validThru+"T00:00:00Z")<new Date(today+"T00:00:00Z");}
type AdminClient=ReturnType<typeof createClient>;
async function consume(admin:AdminClient,key:string,max:number,windowSeconds:number){const {data,error}=await admin.rpc("consume_staff_login_attempt",{p_login_key:await sha256Hex(key),p_max_attempts:max,p_window_seconds:windowSeconds});if(error)throw error;return data as {allowed?:boolean;retry_after_seconds?:number}|null;}
async function clear(admin:AdminClient,key:string){await admin.rpc("clear_staff_login_attempt",{p_login_key:await sha256Hex(key)});}
const rateLimited=(r:{retry_after_seconds?:number}|null)=>json({error:"RATE_LIMIT",retry_after_seconds:r?.retry_after_seconds||600},429);
const STAFF_COLUMNS="id,emp_id,name,department,role,email,status,valid_thru,phone,address";
async function findStaffByEmail(admin:AdminClient,email:string){const {data,error}=await admin.from("staff").select(STAFF_COLUMNS).ilike("email",escapeLike(email)).eq("status","ACTIVE").limit(2);if(error)throw error;return data&&data.length===1?data[0]:null;}
async function requireUser(req:Request,admin:AdminClient){const authHeader=req.headers.get("Authorization")||"";const token=authHeader.startsWith("Bearer ")?authHeader.slice(7).trim():"";if(!token)return null;const {data,error}=await admin.auth.getUser(token);const email=data?.user?.email?.trim().toLowerCase();if(error||!email)return null;return {token,email};}
async function setPinServerSide(admin:AdminClient,staffId:string,pin:string){for(const fn of ["set_staff_pin_internal","set_staff_pin"]){const {data,error}=await admin.rpc(fn,{p_staff_id:staffId,p_pin:pin});if(error){console.error(`change_pin: ${fn} failed:`,error.message);continue;}if(data===false)continue;const {data:ok,error:verifyError}=await admin.rpc("verify_staff_pin_internal",{p_staff_id:staffId,p_pin:pin});if(!verifyError&&ok===true)return true;}return false;}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return json({error:"METHOD_NOT_ALLOWED"},405);
 const supabaseUrl=Deno.env.get("SUPABASE_URL"),serviceRoleKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),anonKey=Deno.env.get("SUPABASE_ANON_KEY");
 if(!supabaseUrl||!serviceRoleKey||!anonKey)return json({error:"SERVER_CONFIGURATION_ERROR"},500);
 const authOpts={auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}},admin=createClient(supabaseUrl,serviceRoleKey,authOpts),ip=clientIp(req);
 try{
  const body=await req.json().catch(()=>({})),action=String(body?.action||"attendance");
  if(action==="staff_login"){
   const loginId=String(body?.login_id||"").trim().slice(0,120),pin=String(body?.pin||"").trim();
   if(!loginId||!/^\d{4}$/.test(pin))return json({error:"STAFF_LOGIN_ID_AND_4_DIGIT_PIN_REQUIRED"},400);
   const ipLimit=await consume(admin,`staff-ip:${ip}`,PER_IP_MAX,PER_IP_WINDOW);if(ipLimit?.allowed===false)return rateLimited(ipLimit);
   const normalized=loginId.toLowerCase();let staff:any=null;
   if(normalized.includes("@"))staff=await findStaffByEmail(admin,normalized);
   else {const {data,error}=await admin.from("staff").select(STAFF_COLUMNS).eq("emp_id",loginId.toUpperCase()).eq("status","ACTIVE").maybeSingle();if(error)throw error;staff=data;}
   const identityKey=staff?`staff:${staff.id}`:`unknown:${normalized}`,idLimit=await consume(admin,identityKey,PER_STAFF_MAX,PER_STAFF_WINDOW);if(idLimit?.allowed===false)return rateLimited(idLimit);
   const staffEmail=String(staff?.email||"").trim().toLowerCase();let pinOk=false;
   if(staff&&staffEmail){const {data,error}=await admin.rpc("verify_staff_pin_internal",{p_staff_id:staff.id,p_pin:pin});if(error)throw error;pinOk=data===true;}
   if(!pinOk)return json({error:"INVALID_PIN"},401);
   const {data:adminRow}=await admin.from("admin_users").select("email").eq("email",staffEmail).eq("active",true).maybeSingle();if(adminRow)return json({error:"INVALID_PIN"},401);
   if(isExpired(staff.valid_thru))return json({error:"ID_CARD_EXPIRED",valid_thru:staff.valid_thru},403);
   const metadata={staff_id:staff.id,emp_id:staff.emp_id,name:staff.name,account_type:"staff"};
   const {data:existingId,error:lookupError}=await admin.rpc("get_auth_user_id_by_email",{p_email:staffEmail});if(lookupError)throw lookupError;
   let userId:string|null=existingId||null;
   if(!userId){const {data:created,error:createError}=await admin.auth.admin.createUser({email:staffEmail,password:randomSecret(),email_confirm:true,user_metadata:metadata});if(createError){console.error("staff login: createUser failed:",createError.message);return json({error:"STAFF_AUTH_ACCOUNT_CREATE_FAILED"},500);}userId=created.user?.id||null;}
   if(!userId)return json({error:"STAFF_AUTH_ACCOUNT_MISSING"},500);
   const {error:syncError}=await admin.auth.admin.updateUserById(userId,{password:randomSecret(),user_metadata:metadata});if(syncError){console.error("staff login: Auth sync failed:",syncError.message);return json({error:"STAFF_AUTH_PASSWORD_SYNC_FAILED"},500);}
   const {data:link,error:linkError}=await admin.auth.admin.generateLink({type:"magiclink",email:staffEmail}),tokenHash=link?.properties?.hashed_token;
   if(linkError||!tokenHash){console.error("staff login: generateLink failed:",linkError?.message||"no token");return json({error:"STAFF_AUTH_SESSION_CREATE_FAILED"},500);}
   const anon=createClient(supabaseUrl,anonKey,authOpts),{data:verified,error:verifyError}=await anon.auth.verifyOtp({type:"email",token_hash:tokenHash}),s=verified?.session;
   if(verifyError||!s?.access_token||!s?.refresh_token){console.error("staff login: verifyOtp failed:",verifyError?.message||"no session");return json({error:"STAFF_AUTH_SESSION_CREATE_FAILED"},500);}
   await clear(admin,identityKey);
   return json({success:true,session:{access_token:s.access_token,refresh_token:s.refresh_token,expires_in:s.expires_in,expires_at:s.expires_at,token_type:s.token_type||"bearer",user:s.user||null},staff:{id:staff.id,emp_id:staff.emp_id,name:staff.name,department:staff.department,role:staff.role,email:staffEmail,status:staff.status,valid_thru:staff.valid_thru,phone:staff.phone,address:staff.address}});
  }
  if(action==="change_pin"){
   const user=await requireUser(req,admin);if(!user)return json({error:"AUTHENTICATION_REQUIRED"},401);
   const current=String(body?.current_pin||"").trim(),next=String(body?.new_pin||"").trim();if(!/^\d{4}$/.test(current)||!/^\d{4}$/.test(next))return json({error:"PIN_MUST_BE_4_DIGITS"},400);
   const ipLimit=await consume(admin,`staff-ip:${ip}`,PER_IP_MAX,PER_IP_WINDOW);if(ipLimit?.allowed===false)return rateLimited(ipLimit);
   const staff=await findStaffByEmail(admin,user.email);if(!staff)return json({error:"STAFF_PROFILE_NOT_LINKED"},403);
   const key=`staff:${staff.id}`,idLimit=await consume(admin,key,PER_STAFF_MAX,PER_STAFF_WINDOW);if(idLimit?.allowed===false)return rateLimited(idLimit);
   const {data:ok,error:pinError}=await admin.rpc("verify_staff_pin_internal",{p_staff_id:staff.id,p_pin:current});if(pinError)throw pinError;if(ok!==true)return json({error:"INVALID_PIN"},401);
   if(!await setPinServerSide(admin,staff.id,next))return json({error:"PIN_UPDATE_FAILED"},400);await clear(admin,key);return json({success:true});
  }
  if(action!=="attendance")return json({error:"UNKNOWN_ACTION"},400);
  const user=await requireUser(req,admin);if(!user)return json({error:"AUTHENTICATION_REQUIRED"},401);
  const qrToken=String(body?.qr_token||"").trim(),pin=String(body?.pin||"").trim();if(!/^\d{4}$/.test(pin)||qrToken.length<20||qrToken.length>100)return json({error:"QR_TOKEN_AND_4_DIGIT_PIN_REQUIRED"},400);
  const ipLimit=await consume(admin,`staff-ip:${ip}`,PER_IP_MAX,PER_IP_WINDOW);if(ipLimit?.allowed===false)return rateLimited(ipLimit);
  const staff=await findStaffByEmail(admin,user.email);if(!staff)return json({error:"STAFF_PROFILE_NOT_LINKED"},403);if(isExpired(staff.valid_thru))return json({error:"ID_CARD_EXPIRED",valid_thru:staff.valid_thru},403);
  const key=`staff:${staff.id}`,idLimit=await consume(admin,key,PER_STAFF_MAX,PER_STAFF_WINDOW);if(idLimit?.allowed===false)return rateLimited(idLimit);
  const {data:pinOk,error:pinError}=await admin.rpc("verify_staff_pin_internal",{p_staff_id:staff.id,p_pin:pin});if(pinError)throw pinError;if(pinOk!==true)return json({error:"INVALID_PIN"},401);await clear(admin,key);

  // Server-side enforcement for the Ashiana Public School 50 m geofence.
  // Coordinates are not stored; the server only validates this punch request.
  const location=body?.location;
  const lat=Number(location?.latitude),lon=Number(location?.longitude),accuracy=Number(location?.accuracy_m),capturedAt=Number(location?.timestamp);
  if(!Number.isFinite(lat)||lat < -90||lat > 90||!Number.isFinite(lon)||lon < -180||lon > 180||!Number.isFinite(accuracy)||!Number.isFinite(capturedAt)){
    return json({error:"GEOFENCE_LOCATION_REQUIRED",message:"Precise location is required to mark staff attendance. Enable location and try again."},403);
  }
  if(accuracy<=0||accuracy>MAX_LOCATION_ACCURACY_METERS){
    return json({error:"GEOFENCE_ACCURACY_TOO_LOW",message:"GPS accuracy must be 25 metres or better. Move outdoors, enable precise location, and try again."},403);
  }
  const locationAge=Date.now()-capturedAt;
  if(locationAge < -15000||locationAge > MAX_LOCATION_AGE_MS){
    return json({error:"GEOFENCE_LOCATION_STALE",message:"Location is out of date. Refresh your location and try again."},403);
  }
  const toRad=(value:number)=>value*Math.PI/180;
  const dLat=toRad(lat-SCHOOL_GEOFENCE_LAT),dLon=toRad(lon-SCHOOL_GEOFENCE_LON);
  const h=Math.sin(dLat/2)**2+Math.cos(toRad(SCHOOL_GEOFENCE_LAT))*Math.cos(toRad(lat))*Math.sin(dLon/2)**2;
  const distanceMeters=6371000*2*Math.atan2(Math.sqrt(h),Math.sqrt(1-h));
  // The measured position must be within 50 m; GPS accuracy is validated separately.
  if(distanceMeters>GEOFENCE_RADIUS_METERS){
    return json({error:"GEOFENCE_OUTSIDE",message:"You are outside the 50-metre school attendance zone. Attendance has not been marked.",distance_m:Math.round(distanceMeters),radius_m:GEOFENCE_RADIUS_METERS,accuracy_m:Math.round(accuracy)},403);
  }

  const now=new Date(),{data:qr,error:qrError}=await admin.from("attendance_qr_sessions").select("id,token,attendance_date,expires_at,active").eq("token",qrToken).eq("active",true).maybeSingle();if(qrError||!qr||new Date(qr.expires_at)<=now)return json({error:"INVALID_OR_EXPIRED_QR"},400);
  const today=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).format(now);if(qr.attendance_date!==today)return json({error:"QR_DATE_MISMATCH"},400);
  const {data:latest}=await admin.from("attendance_punches").select("id,type,timestamp,created_at").eq("staff_id",staff.id).eq("attendance_date",today).order("created_at",{ascending:false}).limit(1).maybeSingle();
  if(latest&&now.getTime()-new Date(latest.created_at).getTime()<30000)return json({error:"DUPLICATE_SCAN_WAIT_30_SECONDS"},409);
  const type=latest?.type==="IN"?"OUT":"IN",timestamp=new Intl.DateTimeFormat("en-GB",{timeZone:"Asia/Kolkata",hour:"2-digit",minute:"2-digit",hour12:false}).format(now);
  const {data:punch,error:insertError}=await admin.rpc("record_attendance_punch_service",{p_staff_id:staff.id,p_attendance_date:today,p_type:type,p_timestamp:timestamp,p_method:"QR_PIN"});
  if(insertError){const msg=String(insertError.message||"");console.error("attendance RPC failed:",msg);if(msg.includes("DUPLICATE_SCAN_WAIT_30_SECONDS"))return json({error:"DUPLICATE_SCAN_WAIT_30_SECONDS"},409);if(msg.includes("PUNCH_SEQUENCE_CONFLICT"))return json({error:"PUNCH_SEQUENCE_CONFLICT"},409);return json({error:"ATTENDANCE_SAVE_FAILED"},500);}
  const {data:attendanceSummary,error:summaryError}=await admin.rpc("calculate_staff_attendance_day",{p_staff_id:staff.id,p_attendance_date:today});
  if(summaryError){console.error("attendance summary failed:",summaryError.message);return json({success:true,message:type==="IN"?"Attendance IN marked successfully":"Attendance OUT marked successfully",punch,attendance_summary:null,attendance_summary_error:"CALCULATION_UNAVAILABLE"});}
  return json({success:true,message:type==="IN"?"Attendance IN marked successfully":"Attendance OUT marked successfully",punch,attendance_summary:attendanceSummary});
 }catch(error){console.error("verify-attendance error:",error instanceof Error?error.message:String(error));return json({error:"SERVER_ERROR"},500);}
});