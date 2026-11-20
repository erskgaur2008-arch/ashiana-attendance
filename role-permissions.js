(function(){
  "use strict";
  const MODULE_LABELS={
    attendance:"Attendance",leaves:"Leaves",student_portal:"Student Portal",
    communication:"Communication",corrections:"Attendance Corrections",
    live_location:"Staff Live Location",fee_confirmations:"Fee Confirmations",
    fees:"Fees Management",settings:"Settings",role_management:"Role Management",security:"Security"
  };
  const PERMISSIONS=["view","create","edit","delete","approve","manage"];
  const LABELS={view:"View",create:"Create",edit:"Edit",delete:"Delete",approve:"Approve",manage:"Manage"};
  const $=id=>document.getElementById(id);
  const esc=v=>String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function client(){return window.__ashianaMainSupabaseClient||window.supabaseClient||null;}
  function status(message,bad){const el=$("role-permissions-status");if(el){el.textContent=message;el.className="rounded-lg border p-3 text-sm "+(bad?"border-rose-300 bg-rose-50 text-rose-800":"border-emerald-300 bg-emerald-50 text-emerald-900");}}
  function renderRows(rows){
    const host=$("role-permissions-rows");if(!host)return;
    const role=$("role-permissions-role")?.value||"PRINCIPAL";
    const filtered=(rows||[]).filter(r=>r.role_key===role);
    host.innerHTML=filtered.map(r=>'<section class="rounded-xl border border-slate-200 bg-white p-3 mb-3" data-module="'+esc(r.module_key)+'"><h3 class="font-bold text-slate-900 mb-3">'+esc(MODULE_LABELS[r.module_key]||r.module_key)+'</h3><div class="grid grid-cols-2 sm:grid-cols-3 gap-2">'+PERMISSIONS.map(p=>'<label class="flex items-center gap-2 rounded-lg bg-slate-50 p-2 text-sm text-slate-800"><input type="checkbox" data-permission="'+p+'" '+(r["can_"+p]?"checked":"")+'><span>'+LABELS[p]+'</span></label>').join("")+'</div><button type="button" class="mt-3 rounded-lg bg-emerald-800 px-3 py-2 text-xs font-bold text-white" data-save-module="'+esc(r.module_key)+'">Save '+esc(MODULE_LABELS[r.module_key]||r.module_key)+'</button></section>').join("");
    if(!filtered.length)host.textContent="No modules are configured yet.";
    host.querySelectorAll("[data-save-module]").forEach(btn=>btn.addEventListener("click",()=>saveModule(btn.dataset.saveModule)));
  }
  let cache=[];
  async function load(){
    const c=client();if(!c?.rpc){status("Login client is not ready. Please refresh and sign in again.",true);return;}
    status("Loading role permissions…");
    const {data,error}=await c.rpc("admin_list_role_module_permissions");
    if(error){status(error.message||"Unable to load permissions. Admin access is required.",true);return;}
    cache=Array.isArray(data)?data:[];
    renderRows(cache);status("Permissions loaded. Changes are saved per role and module.");
  }
  async function saveModule(module){
    const section=$("role-permissions-rows")?.querySelector('[data-module="'+CSS.escape(module)+'"]');
    if(!section)return;
    const role=$("role-permissions-role")?.value||"";
    const values={};PERMISSIONS.forEach(p=>values["p_can_"+p]=!!section.querySelector('[data-permission="'+p+'"]')?.checked);
    const c=client();if(!c?.rpc)return status("Login client is not ready.",true);
    const button=section.querySelector("[data-save-module]");if(button)button.disabled=true;
    const {error}=await c.rpc("admin_set_role_module_permission",{
      p_role_key:role,p_module_key:module,
      p_can_view:values.p_can_view,p_can_create:values.p_can_create,
      p_can_edit:values.p_can_edit,p_can_delete:values.p_can_delete,
      p_can_approve:values.p_can_approve,p_can_manage:values.p_can_manage
    });
    if(button)button.disabled=false;
    if(error){status(error.message||"Could not save this permission.",true);return;}
    status("Saved "+(MODULE_LABELS[module]||module)+" permissions for "+role+".");
    await load();
  }
  window.openRolePermissionManager=async function(){
    const modal=$("role-permissions-modal");if(!modal)return;
    modal.classList.remove("hidden");modal.classList.add("flex");
    await load();
  };
  window.closeRolePermissionManager=function(){
    const modal=$("role-permissions-modal");if(modal){modal.classList.add("hidden");modal.classList.remove("flex");}
  };
  document.addEventListener("DOMContentLoaded",()=>{
    $("role-permissions-role")?.addEventListener("change",()=>renderRows(cache));
  });
})();