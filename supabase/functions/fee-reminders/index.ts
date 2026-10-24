import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const headers = {
  "Access-Control-Allow-Origin": "https://erskgaur2008-arch.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-fee-reminder-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers });
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_TOKEN_URL = "https://oauth2.googleapis.com/token";
type ServiceAccount = { project_id: string; client_email: string; private_key: string };
type Candidate = {
  student_id: string; fee_account_id: string; installment_id: string; enroll_no: string;
  student_name: string; class_name: string; section: string; fee_name: string;
  amount_due_paise: number; due_date: string; reminder_stage: "PRE_DUE_3D" | "DUE_DATE" | "OVERDUE_7D";
};
type Subscription = {
  id: string; platform: "web" | "android"; endpoint: string | null;
  subscription: Record<string, unknown> | null; device_token: string | null;
};
function b64url(value: string | Uint8Array) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let i=0;i<bytes.length;i+=0x8000) binary += String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)));
  return btoa(binary).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");
}
function pemBytes(pem: string) {
  const clean=pem.replace(/\\n/g,"\n").replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,"");
  const raw=atob(clean); return Uint8Array.from(raw,c=>c.charCodeAt(0));
}
async function fcmToken(account: ServiceAccount) {
  const now=Math.floor(Date.now()/1000);
  const unsigned=b64url(JSON.stringify({alg:"RS256",typ:"JWT"}))+"."+b64url(JSON.stringify({
    iss:account.client_email,scope:FCM_SCOPE,aud:FCM_TOKEN_URL,iat:now,exp:now+3600,
  }));
  const key=await crypto.subtle.importKey("pkcs8",pemBytes(account.private_key),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);
  const sig=new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,new TextEncoder().encode(unsigned)));
  const response=await fetch(FCM_TOKEN_URL,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},
    body:new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion:unsigned+"."+b64url(sig)})});
  const data=await response.json().catch(()=>({}));
  if(!response.ok||!data.access_token) throw new Error("FCM OAuth token could not be created");
  return String(data.access_token);
}
async function sendFcm(token:string,projectId:string,deviceToken:string,title:string,body:string,stage:string) {
  const response=await fetch("https://fcm.googleapis.com/v1/projects/"+encodeURIComponent(projectId)+"/messages:send",{
    method:"POST",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},
    body:JSON.stringify({message:{token:deviceToken,notification:{title,body},
      data:{category:"fee_reminder",reminderStage:stage,url:"/?login=student"},
      android:{priority:"high",notification:{channel_id:"school_updates",sound:"default"}}}})});
  const data=await response.json().catch(()=>({}));
  return {ok:response.ok,status:response.status,detail:String(data?.error?.details?.[0]?.errorCode||data?.error?.status||"")};
}
function serviceAccount():ServiceAccount|null {
  try { const value=JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT_JSON")||""); return value?.project_id&&value?.client_email&&value?.private_key?value:null; }
  catch { return null; }
}
function indiaDate() {
  const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date());
  const values=Object.fromEntries(parts.map(p=>[p.type,p.value]));
  return values.year+"-"+values.month+"-"+values.day;
}
function rupees(paise:number) { return "₹"+(Number(paise||0)/100).toLocaleString("en-IN",{minimumFractionDigits:2,maximumFractionDigits:2}); }
function stageText(stage:Candidate["reminder_stage"]) {
  if(stage==="PRE_DUE_3D") return {title:"Fees Due in 3 Days",prefix:"is due in 3 days"};
  if(stage==="DUE_DATE") return {title:"Fees Due Today",prefix:"is due today"};
  return {title:"Overdue Fees Reminder",prefix:"was due on"};
}
Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers});
  if(req.method!=="POST") return json({error:"METHOD_NOT_ALLOWED"},405);
  const expected=Deno.env.get("FEE_REMINDER_CRON_SECRET")||"";
  const provided=req.headers.get("x-fee-reminder-secret")||"";
  if(!expected||provided.length!==expected.length||!crypto.subtle) return json({error:"UNAUTHORIZED"},401);
  let same=true;
  for(let i=0;i<expected.length;i++) same = same && (expected.charCodeAt(i)===provided.charCodeAt(i));
  if(!same) return json({error:"UNAUTHORIZED"},401);
  const url=Deno.env.get("SUPABASE_URL")||"";
  const serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
  if(!url||!serviceKey) return json({error:"SERVER_CONFIGURATION_ERROR"},503);
  const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const today=indiaDate();
  const {data:candidates,error:candidateError}=await service.rpc("fee_reminder_candidates",{p_today:today});
  if(candidateError) { console.error("Fee reminder candidate lookup failed",candidateError.message); return json({error:"CANDIDATE_LOOKUP_FAILED"},500); }
  const rows=(candidates||[]) as Candidate[];
  const vapidPublic=Deno.env.get("VAPID_PUBLIC_KEY")||"",vapidPrivate=Deno.env.get("VAPID_PRIVATE_KEY")||"",vapidSubject=Deno.env.get("VAPID_SUBJECT")||"";
  const webConfigured=Boolean(vapidPublic&&vapidPrivate&&vapidSubject);
  if(webConfigured) webpush.setVapidDetails(vapidSubject,vapidPublic,vapidPrivate);
  const account=serviceAccount();
  let androidToken="";
  const {data:allSubscriptions,error:subError}=await service.from("student_push_subscriptions")
    .select("id,platform,endpoint,subscription,device_token,enroll_no,school_code").eq("school_code","ashiana");
  if(subError) { console.error("Fee reminder subscription lookup failed",subError.message); return json({error:"SUBSCRIPTION_LOOKUP_FAILED"},500); }
  const subscriptions=(allSubscriptions||[]) as (Subscription & {enroll_no:string;school_code:string})[];
  const stats={date:today,candidates:rows.length,inAppCreated:0,pushSent:0,pushFailed:0,pushSuppressed:0,duplicates:0};
  for(const row of rows) {
    const stage=stageText(row.reminder_stage);
    const title=stage.title;
    const duePhrase=row.reminder_stage==="OVERDUE_7D"?"was due on "+row.due_date:"is due "+(row.reminder_stage==="PRE_DUE_3D"?"on "+row.due_date:"today");
    const message=row.fee_name+" "+duePhrase+". Outstanding balance: "+rupees(row.amount_due_paise)+". Please open Ashiana Attendance to pay.";
    const {error:attemptError}=await service.from("fee_reminder_attempts").insert({
      fee_account_id:row.fee_account_id,installment_id:row.installment_id,reminder_kind:"IN_APP",
      reminder_stage:row.reminder_stage,due_date:row.due_date,outcome:"QUEUED",
    });
    if(attemptError) { if(attemptError.code==="23505"){stats.duplicates++;continue;} console.error("Reminder attempt insert failed",attemptError.message); continue; }
    const {error:inAppError}=await service.from("fee_student_reminders").insert({
      school_code:"ashiana",student_id:row.student_id,fee_account_id:row.fee_account_id,
      installment_id:row.installment_id,reminder_stage:row.reminder_stage,title,message,
      amount_due_paise:row.amount_due_paise,due_date:row.due_date,
    });
    if(inAppError) {
      await service.from("fee_reminder_attempts").update({outcome:"FAILED",reason:"IN_APP_SAVE_FAILED"}).eq("fee_account_id",row.fee_account_id).eq("installment_id",row.installment_id).eq("reminder_kind","IN_APP").eq("reminder_stage",row.reminder_stage);
      console.error("In-app reminder save failed",inAppError.message); continue;
    }
    stats.inAppCreated++;
    await service.from("fee_reminder_attempts").update({outcome:"SENT",sent_at:new Date().toISOString()})
      .eq("fee_account_id",row.fee_account_id).eq("installment_id",row.installment_id).eq("reminder_kind","IN_APP").eq("reminder_stage",row.reminder_stage);
    const normalizeEnroll=(value:string|undefined|null)=>String(value||"").trim().toUpperCase();
    const matching=subscriptions.filter(s=>normalizeEnroll(s.enroll_no)===normalizeEnroll(row.enroll_no));
    if (!matching.length) {
      // Log counts only; do not expose student identifiers or device tokens.
      console.warn("Fee reminder push suppressed: no matching registered device", {
        stage: row.reminder_stage,
        subscriptionCount: subscriptions.length,
        candidateEnrollmentPresent: Boolean(normalizeEnroll(row.enroll_no)),
      });
    }
    if(!matching.length) {
      stats.pushSuppressed++;
      await service.from("fee_reminder_attempts").insert({fee_account_id:row.fee_account_id,installment_id:row.installment_id,
        reminder_kind:"PUSH",reminder_stage:row.reminder_stage,due_date:row.due_date,outcome:"SUPPRESSED",reason:"NO_REGISTERED_DEVICE"});
      continue;
    }
    let webSent=0,androidSent=0,failed=0;
    if(matching.some(s=>s.platform==="android")&&account&&!androidToken) {
      try { androidToken=await fcmToken(account); } catch(e) { console.error("FCM setup failed",(e as Error).message); }
    }
    const jobs:Promise<void>[]=[];
    for(const sub of matching) {
      if(sub.platform==="web") {
        if(!webConfigured||!sub.subscription) {
          failed++;
          console.error("Fee reminder web push unavailable", {
            vapidConfigured: webConfigured,
            subscriptionAvailable: Boolean(sub.subscription),
          });
          continue;
        }
        jobs.push(webpush.sendNotification(sub.subscription as {endpoint:string;keys:{p256dh:string;auth:string}},
          JSON.stringify({title,body:message,category:"fee_reminder",tag:"fee:"+row.installment_id+":"+row.reminder_stage,url:"/?login=student"}))
          .then(()=>{webSent++;}).catch(async(e)=>{
            failed++;
            const status=Number((e as {statusCode?:number}).statusCode||0);
            console.error("Fee reminder web push failed", { status, errorName: String((e as {name?:string}).name||"Error") });
            if(status===404||status===410) await service.from("student_push_subscriptions").delete().eq("id",sub.id);
          }));
      } else if(sub.platform==="android") {
        if(!account||!androidToken||!sub.device_token) {
          failed++;
          console.error("Fee reminder Android push unavailable", {
            serviceAccountConfigured: Boolean(account),
            accessTokenAvailable: Boolean(androidToken),
            deviceTokenAvailable: Boolean(sub.device_token),
          });
          continue;
        }
        jobs.push(sendFcm(androidToken,account.project_id,sub.device_token,title,message,row.reminder_stage).then(async result=>{
          if(result.ok) {
            androidSent++;
          } else {
            failed++;
            // FCM status and safe error code help diagnose delivery without logging tokens.
            console.error("Fee reminder Android push failed", { status: result.status, code: result.detail || "UNKNOWN" });
            if(result.detail==="UNREGISTERED"||result.status===404) {
              // Subscription cleanup must not cause this same delivery failure to be counted twice.
              try {
                const {error:deleteError}=await service.from("student_push_subscriptions").delete().eq("id",sub.id);
                if(deleteError) console.warn("Invalid Android subscription cleanup failed", { code: deleteError.code || "UNKNOWN" });
              } catch {
                console.warn("Invalid Android subscription cleanup threw");
              }
            }
          }
        }).catch((error:unknown)=>{
          failed++;
          console.error("Fee reminder Android push request threw", {
            errorName: error instanceof Error ? error.name : "UnknownError",
          });
        }));
      }
    }
    for(let i=0;i<jobs.length;i+=20) await Promise.allSettled(jobs.slice(i,i+20));
    const sent=webSent+androidSent;
    stats.pushSent+=sent;stats.pushFailed+=failed;
    console.info("Fee reminder delivery summary", {
      stage: row.reminder_stage,
      webSent,
      androidSent,
      failed,
      matchedSubscriptions: matching.length,
    });
    await service.from("fee_reminder_attempts").insert({fee_account_id:row.fee_account_id,installment_id:row.installment_id,
      reminder_kind:"PUSH",reminder_stage:row.reminder_stage,due_date:row.due_date,
      outcome:sent>0?"SENT":"FAILED",reason:sent>0?null:"NO_DELIVERY_SUCCEEDED",sent_at:sent>0?new Date().toISOString():null});
  }
  return json({success:true,...stats});
});
