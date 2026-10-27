import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { generateRegistrationOptions, verifyRegistrationResponse, generateAuthenticationOptions, verifyAuthenticationResponse } from "npm:@simplewebauthn/server@13.1.2";

const headers = { "Access-Control-Allow-Origin":"https://erskgaur2008-arch.github.io", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS", "Content-Type":"application/json", "Cache-Control":"no-store" };
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
const rpID="erskgaur2008-arch.github.io", expectedOrigin="https://erskgaur2008-arch.github.io", rpName="Ashiana Public School Attendance";
const b64=(v:Uint8Array)=>{let s="";for(let i=0;i<v.length;i+=8192)s+=String.fromCharCode(...v.subarray(i,i+8192));return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"");};
const unb64=(v:string)=>Uint8Array.from(atob(v.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-v.length%4)%4)),c=>c.charCodeAt(0));
const challenge=()=>b64(crypto.getRandomValues(new Uint8Array(32)));
const hash=async(v:string)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v))),b=>b.toString(16).padStart(2,"0")).join("");

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers});
 if(req.method!=="POST")return json({error:"METHOD_NOT_ALLOWED"},405);
 const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!key)return json({error:"SERVER_CONFIGURATION_ERROR"},503);
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 let b:Record<string,unknown>;try{b=await req.json()}catch{return json({error:"INVALID_JSON"},400)}
 const role=String(b.role||""),action=String(b.action||"");
 if(!["admin","student"].includes(role))return json({error:"INVALID_ROLE"},400);
 let subjectId="",student:Record<string,unknown>|null=null;
 if(role==="admin"){
   const h=req.headers.get("Authorization")||"",jwt=h.startsWith("Bearer ")?h.slice(7).trim():"";
   if(!jwt)return json({error:"AUTHENTICATION_REQUIRED"},401);
   const {data:u,error:ue}=await db.auth.getUser(jwt),email=String(u.user?.email||"").trim().toLowerCase();
   if(ue||!email)return json({error:"AUTHENTICATION_REQUIRED"},401);
   const {data:rows,error}=await db.from("admin_users").select("email,role").eq("active",true).limit(500);
   const matches=(rows||[]).filter((r:{email:string})=>String(r.email||"").trim().toLowerCase()===email);
   if(error||matches.length!==1)return json({error:"ADMIN_REQUIRED"},403);
   subjectId=email;
 }else if((action==="authentication-options"||action==="authentication-verify") && role==="student"){
   const session=String(b.session_token||"").trim();
   if(session){
     if(!/^[a-f0-9]{64}$/i.test(session))return json({error:"STUDENT_SESSION_REQUIRED"},401);
     const {data:id,error}=await db.rpc("student_session_student_id",{p_token:session});
     if(error||typeof id!=="string"||!id)return json({error:"STUDENT_SESSION_EXPIRED"},401);
     subjectId=id;
     const {data:row,error:re}=await db.from("student_roster").select("id,enroll_no,name,status,school_code").eq("id",id).eq("school_code","ashiana").maybeSingle();
     if(re||!row||String(row.status||"").toLowerCase()!=="active")return json({error:"STUDENT_SESSION_EXPIRED"},401);
     student=row;
   }else{
     const enroll=String(b.admission_no||"").trim();
     if(!enroll||enroll.length>100)return json({error:"ADMISSION_NUMBER_REQUIRED"},400);
     const {data:rows,error}=await db.from("student_roster").select("id,enroll_no,name,status,school_code").eq("school_code","ashiana").ilike("enroll_no",enroll).limit(2);
     if(error||!rows||rows.length!==1||String(rows[0].status||"").toLowerCase()!=="active")return json({error:"STUDENT_NOT_FOUND"},401);
     student=rows[0];subjectId=String(student.id);
   }
 }else{
   const session=String(b.session_token||"").trim();
   if(!/^[a-f0-9]{64}$/i.test(session))return json({error:"STUDENT_SESSION_REQUIRED"},401);
   const {data:id,error}=await db.rpc("student_session_student_id",{p_token:session});
   if(error||typeof id!=="string"||!id)return json({error:"STUDENT_SESSION_EXPIRED"},401);
   subjectId=id;
   const {data:row,error:re}=await db.from("student_roster").select("id,enroll_no,name,status,school_code").eq("id",id).eq("school_code","ashiana").maybeSingle();
   if(re||!row||String(row.status||"").toLowerCase()!=="active")return json({error:"STUDENT_SESSION_EXPIRED"},401);
   student=row;
 }
 try{
  if(action==="status"){
   const {data,error}=await db.from("portal_webauthn_credentials").select("id,enabled").eq("subject_type",role).eq("subject_id",subjectId);
   if(error)throw error;const rows=data||[];return json({enabled:rows.some((r:{enabled:boolean})=>r.enabled),credential_count:rows.length});
  }
  if(action==="disable"){
   const {error}=await db.from("portal_webauthn_credentials").update({enabled:false}).eq("subject_type",role).eq("subject_id",subjectId);
   if(error)throw error;return json({success:true,enabled:false});
  }
  if(action==="enable"){
   const {data:existing,error}=await db.from("portal_webauthn_credentials").select("id").eq("subject_type",role).eq("subject_id",subjectId);
   if(error)throw error;
   if(!existing?.length)return json({error:"PASSKEY_NOT_REGISTERED"},404);
   const {error:updateError}=await db.from("portal_webauthn_credentials").update({enabled:true}).eq("subject_type",role).eq("subject_id",subjectId);
   if(updateError)throw updateError;
   return json({success:true,enabled:true});
  }
  if(action==="registration-options"){
   const {data:existing,error}=await db.from("portal_webauthn_credentials").select("credential_id").eq("subject_type",role).eq("subject_id",subjectId);
   if(error)throw error;
   const ch=challenge(),options=await generateRegistrationOptions({
    rpName,rpID,userID:new TextEncoder().encode(role+":"+subjectId),
    userName:role==="admin"?subjectId:String(student?.enroll_no||subjectId),
    userDisplayName:String(student?.name||(role==="admin"?"Ashiana Administrator":"Ashiana Student")),
    attestationType:"none",authenticatorSelection:{residentKey:"preferred",userVerification:"required"},
    excludeCredentials:(existing||[]).map((r:{credential_id:string})=>({id:r.credential_id,type:"public-key" as const})),challenge:ch
   });
   await db.from("portal_webauthn_challenges").delete().eq("subject_type",role).eq("subject_id",subjectId).eq("purpose","registration");
   const {error:ie}=await db.from("portal_webauthn_challenges").insert({subject_type:role,subject_id:subjectId,challenge:options.challenge,purpose:"registration",expires_at:new Date(Date.now()+300000).toISOString()});
   if(ie)throw ie;return json({options});
  }
  if(action==="registration-verify"){
   const credential=b.credential as {id?:string;response?:{transports?:string[]}}|undefined;
   if(!credential||typeof credential.id!=="string")return json({error:"INVALID_CREDENTIAL"},400);
   const {data:ch,error:ce}=await db.rpc("consume_portal_webauthn_challenge",{p_subject_type:role,p_subject_id:subjectId,p_purpose:"registration"});
   if(ce)throw ce;if(typeof ch!=="string"||!ch)return json({error:"CHALLENGE_EXPIRED"},400);
   const result=await verifyRegistrationResponse({response:credential as never,expectedChallenge:ch,expectedOrigin,expectedRPID:rpID,requireUserVerification:true});
   if(!result.verified||!result.registrationInfo)return json({error:"PASSKEY_VERIFICATION_FAILED"},401);
   const info=result.registrationInfo,id=info.credential.id;
   const {data:owner,error:oe}=await db.from("portal_webauthn_credentials").select("subject_type,subject_id").eq("credential_id",id).maybeSingle();
   if(oe)throw oe;if(owner&&(owner.subject_type!==role||owner.subject_id!==subjectId))return json({error:"CREDENTIAL_ALREADY_BOUND"},409);
   if(owner)return json({success:true,already_registered:true});
   const {error:se}=await db.from("portal_webauthn_credentials").insert({subject_type:role,subject_id:subjectId,credential_id:id,public_key:b64(info.credential.publicKey),counter:info.credential.counter,transports:credential.response?.transports||[],device_type:info.credentialDeviceType,backed_up:info.credentialBackedUp});
   if(se?.code==="23505")return json({error:"CREDENTIAL_ALREADY_BOUND"},409);if(se)throw se;return json({success:true,enabled:true});
  }
  if(action==="authentication-options"){
   const {data:rows,error}=await db.from("portal_webauthn_credentials").select("credential_id,transports").eq("subject_type",role).eq("subject_id",subjectId).eq("enabled",true);
   if(error)throw error;if(!rows?.length)return json({error:"PASSKEY_NOT_REGISTERED"},404);
   const options=await generateAuthenticationOptions({rpID,userVerification:"required",allowCredentials:rows.map((r:{credential_id:string;transports?:string[]})=>({id:r.credential_id,type:"public-key" as const,transports:r.transports||[]})),challenge:challenge()});
   await db.from("portal_webauthn_challenges").delete().eq("subject_type",role).eq("subject_id",subjectId).eq("purpose","authentication");
   const {error:ie}=await db.from("portal_webauthn_challenges").insert({subject_type:role,subject_id:subjectId,challenge:options.challenge,purpose:"authentication",expires_at:new Date(Date.now()+120000).toISOString()});
   if(ie)throw ie;return json({options});
  }
  if(action==="authentication-verify"){
   const assertion=b.credential as {id?:string}|undefined;if(!assertion||typeof assertion.id!=="string")return json({error:"INVALID_CREDENTIAL"},400);
   const {data:ch,error:ce}=await db.rpc("consume_portal_webauthn_challenge",{p_subject_type:role,p_subject_id:subjectId,p_purpose:"authentication"});
   if(ce)throw ce;if(typeof ch!=="string"||!ch)return json({error:"CHALLENGE_EXPIRED"},400);
   const {data:rows,error}=await db.from("portal_webauthn_credentials").select("id,credential_id,public_key,counter,transports,enabled").eq("subject_type",role).eq("subject_id",subjectId).eq("credential_id",assertion.id).eq("enabled",true).limit(1);
   if(error)throw error;const stored=rows?.[0];if(!stored)return json({error:"PASSKEY_NOT_REGISTERED"},403);
   const verified=await verifyAuthenticationResponse({response:b.credential as never,expectedChallenge:ch,expectedOrigin,expectedRPID:rpID,credential:{id:stored.credential_id,publicKey:unb64(stored.public_key),counter:Number(stored.counter),transports:stored.transports||[]},requireUserVerification:true});
   if(!verified.verified)return json({error:"PASSKEY_VERIFICATION_FAILED"},401);
   const {error:ue}=await db.from("portal_webauthn_credentials").update({counter:verified.authenticationInfo.newCounter,last_used_at:new Date().toISOString()}).eq("id",stored.id).eq("subject_type",role).eq("subject_id",subjectId);
   if(ue)throw ue;
   if(role==="admin")return json({success:true,verified:true,purpose:"portal-unlock"});
   const session=Array.from(crypto.getRandomValues(new Uint8Array(32)),v=>v.toString(16).padStart(2,"0")).join("");
   const {error:se}=await db.from("student_session_tokens").insert({student_id:subjectId,token_hash:await hash(session),expires_at:new Date(Date.now()+30*24*60*60_000).toISOString()});
   if(se)throw se;return json({success:true,verified:true,session_token:session,expires_in:2592000});
  }
  return json({error:"UNKNOWN_ACTION"},400);
 }catch(e){console.error("portal-passkeys error:",e instanceof Error?e.message:String(e));return json({error:"PASSKEY_OPERATION_FAILED"},500)}
});
