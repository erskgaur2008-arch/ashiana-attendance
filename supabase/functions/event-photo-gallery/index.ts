import { createClient } from "npm:@supabase/supabase-js@2.45.4";
const BASE={"Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Content-Type":"application/json","Cache-Control":"no-store"};
const ALLOWED=new Set(["https://erskgaur2008-arch.github.io","https://localhost","http://localhost","capacitor://localhost"]);
const reply=(body:unknown,status=200,headers:Record<string,string>=BASE)=>new Response(JSON.stringify(body),{status,headers});
Deno.serve(async(req)=>{
 const origin=req.headers.get("Origin"),headers={...BASE}; if(origin&&ALLOWED.has(origin))headers["Access-Control-Allow-Origin"]=origin;
 const send=(b:unknown,s=200)=>reply(b,s,headers);
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers}); if(req.method!=="POST")return send({error:"Method not allowed"},405);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!anon||!key)return send({error:"Server configuration unavailable"},500);
 let input:Record<string,unknown>;try{input=await req.json()}catch{return send({error:"Invalid request"},400)}
 const action=String(input.action||"");const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const auth=req.headers.get("Authorization")||"";
 let isAdmin=false;
 if(auth.startsWith("Bearer ")){
   const verifier=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
   const {data}=await verifier.auth.getUser();
   if(data.user){const {data:adminRow}=await admin.from("admin_users").select("id").eq("id",data.user.id).maybeSingle();isAdmin=!!adminRow;}
 }
 const token=typeof input.student_session_token==="string"?input.student_session_token:"";
 let student:any=null;
 if(token.length===64&&/^[a-f0-9]+$/i.test(token)){
   const {data,error}=await admin.rpc("student_portal_bundle_by_session",{p_token:token});
   if(!error&&data?.success&&data?.student)student=data.student;
 }
 const isStaffAdminAction=["admin-list","create-event","update-event","delete-event","upload-photo","delete-photo"].includes(action);
 if(isStaffAdminAction&&!isAdmin)return send({error:"Admin permission required"},403);
 if(action==="student-list"){
   if(!student)return send({error:"Student session expired"},401);
   const cls=String(student.class_name||student.class||"").trim(),sec=String(student.section||"").trim();
   const {data:published,error}=await admin.from("school_events").select("id,title,description,event_date,audience_type,class_name,section,created_at").eq("status","PUBLISHED").order("event_date",{ascending:false}).limit(500);
   if(error)return send({error:"Could not load events"},500);
   // Filter audience in trusted server code, not by interpolating student data into a PostgREST filter.
   const events=(published||[]).filter((e:any)=>e.audience_type==="ALL"||(e.audience_type==="CLASS"&&e.class_name===cls)||(e.audience_type==="SECTION"&&e.class_name===cls&&e.section===sec));
   const ids=events.map((e:any)=>e.id);let photos:any[]=[];
   if(ids.length){const result=await admin.from("school_event_photos").select("id,event_id,storage_path,caption,mime_type").in("event_id",ids).order("created_at");if(result.error)return send({error:"Could not load photos"},500);photos=result.data||[];}
   const items=[];
   for(const e of events){const pp=[];for(const p of photos.filter((x:any)=>x.event_id===e.id)){const {data}=await admin.storage.from("school-event-photos").createSignedUrl(p.storage_path,300);if(data?.signedUrl)pp.push({id:p.id,url:data.signedUrl,caption:p.caption});}items.push({...e,photos:pp});}
   return send({events:items});
 }
 if(action==="admin-list"){
   const {data,error}=await admin.from("school_events").select("*,school_event_photos(id,caption,mime_type,byte_size,storage_path)").order("created_at",{ascending:false}).limit(200);
   if(error)return send({error:"Could not load events"},500);
   const items=[];for(const e of data||[]){const photos=[];for(const p of e.school_event_photos||[]){const {data:s}=await admin.storage.from("school-event-photos").createSignedUrl(p.storage_path,300);photos.push({...p,url:s?.signedUrl||null});}items.push({...e,photos});}
   return send({events:items});
 }
 if(action==="create-event"||action==="update-event"){
   const id=String(input.id||"");const title=String(input.title||"").trim(),description=String(input.description||"").trim(),date=String(input.event_date||"");
   const audience=String(input.audience_type||"ALL"),cls=String(input.class_name||"").trim(),sec=String(input.section||"").trim(),status=String(input.status||"DRAFT");
   if(title.length<2||title.length>180||description.length>3000||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(date)||!["ALL","CLASS","SECTION"].includes(audience)||!["DRAFT","PUBLISHED","ARCHIVED"].includes(status)||(audience!=="ALL"&&!cls)||(audience==="SECTION"&&!sec))return send({error:"Please check event details"},400);
   const row={title,description,event_date:date,audience_type:audience,class_name:audience==="ALL"?null:cls,section:audience==="SECTION"?sec:null,status,updated_at:new Date().toISOString()};
   const result=action==="create-event"?await admin.from("school_events").insert({...row,created_by:(await admin.auth.getUser(auth.replace(/^Bearer /,""))).data.user?.id}).select("id").single():await admin.from("school_events").update(row).eq("id",id).select("id").single();
   if(result.error)return send({error:"Could not save event"},500);return send({success:true,id:result.data.id});
 }
 if(action==="delete-event"){const id=String(input.id||"");const {data:photos}=await admin.from("school_event_photos").select("storage_path").eq("event_id",id);if(photos?.length)await admin.storage.from("school-event-photos").remove(photos.map((p:any)=>p.storage_path));const {error}=await admin.from("school_events").delete().eq("id",id);return error?send({error:"Could not delete event"},500):send({success:true});}
 if(action==="upload-photo"){
   const eventId=String(input.event_id||""),name=String(input.file_name||"photo"),mime=String(input.mime_type||""),b64=String(input.base64||"").replace(/^data:[^;]+;base64,/,""),caption=String(input.caption||"").slice(0,500);
   if(!/^[0-9a-f-]{36}$/i.test(eventId)||!["image/jpeg","image/png","image/webp"].includes(mime)||!b64||b64.length>11200000)return send({error:"Photo must be JPG, PNG or WebP and no larger than 8 MB"},400);
   const {data:event}=await admin.from("school_events").select("id").eq("id",eventId).maybeSingle();if(!event)return send({error:"Event not found"},404);
   let bytes:Uint8Array;try{const raw=atob(b64);bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));}catch{return send({error:"Invalid photo data"},400)}
   if(!bytes.length||bytes.length>8*1024*1024)return send({error:"Photo exceeds 8 MB"},400);
   const ext=mime==="image/jpeg"?"jpg":mime==="image/png"?"png":"webp",path=eventId+"/"+crypto.randomUUID()+"."+ext;
   const {error:uploadError}=await admin.storage.from("school-event-photos").upload(path,bytes,{contentType:mime,upsert:false});
   if(uploadError)return send({error:"Photo upload failed"},500);
   const {data:photo,error}=await admin.from("school_event_photos").insert({event_id:eventId,storage_path:path,caption,mime_type:mime,byte_size:bytes.length}).select("id").single();
   if(error){await admin.storage.from("school-event-photos").remove([path]);return send({error:"Could not save photo record"},500)}
   return send({success:true,id:photo.id});
 }
 if(action==="delete-photo"){const id=String(input.id||"");const {data:p}=await admin.from("school_event_photos").select("storage_path").eq("id",id).maybeSingle();if(!p)return send({error:"Photo not found"},404);await admin.storage.from("school-event-photos").remove([p.storage_path]);const {error}=await admin.from("school_event_photos").delete().eq("id",id);return error?send({error:"Could not delete photo"},500):send({success:true});}
 return send({error:"Unsupported action"},400);
});
