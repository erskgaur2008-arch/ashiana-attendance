(function(){
  function ready(){ return !!(window.supabaseClient && window.currentAuthUser?.type === 'ADMIN'); }
  function el(id){ return document.getElementById(id); }
  function scope(){
    const value=el('admin-portal-class')?.value || '__ALL__';
    if(value==='__ALL__') return null;
    const parts=value.split('|');
    return parts.length===2 ? {class_name:parts[0],section:parts[1]} : null;
  }
  let classes=[];

  async function loadClasses(){
    if(!ready() || !el('admin-portal-class')) return;
    const {data,error}=await window.supabaseClient.from('student_roster').select('class_name,section')
      .eq('school_code',window.APS_STUDENT_SCHOOL).eq('status','ACTIVE').order('class_name').order('section');
    if(error){ window.showToast?.(error.message,'error'); return; }
    const seen=new Set();
    classes=(data||[]).filter(r=>{
      const key=(r.class_name||'')+'|'+(r.section||'');
      if(!r.class_name||!r.section||seen.has(key)) return false;
      seen.add(key); return true;
    });
    const select=el('admin-portal-class');
    select.innerHTML='<option value="__ALL__">All Classes</option>'+classes.map(r=>'<option value="'+escapeText(r.class_name)+'|'+escapeText(r.section)+'">'+escapeText(r.class_name)+' - '+escapeText(r.section)+'</option>').join('');
    render();
  }

  function escapeText(value){
    const div=document.createElement('div');
    div.textContent=value==null?'':String(value);
    return div.innerHTML;
  }

  async function loadStudents(){
    const select=el('admin-portal-student');
    if(!select||!ready()) return;
    let q=window.supabaseClient.from('student_roster').select('id,student_name,enroll_no,class_name,section')
      .eq('school_code',window.APS_STUDENT_SCHOOL).eq('status','ACTIVE')
      .order('class_name').order('section').order('roll_no').order('student_name');
    const s=scope();
    if(s) q=q.eq('class_name',s.class_name).eq('section',s.section);
    const {data,error}=await q;
    if(error){select.innerHTML='<option value="">Unable to load students</option>';window.showToast?.(error.message,'error');return;}
    select.innerHTML='<option value="">Select student</option>'+(data||[]).map(r=>'<option value="'+r.id+'">'+escapeText(r.student_name)+' ('+escapeText(r.enroll_no)+') · '+escapeText(r.class_name)+'-'+escapeText(r.section)+'</option>').join('');
  }

  function render(){
    const host=el('admin-portal-editor');
    if(!host) return;
    const type=el('admin-portal-type')?.value||'notice';
    const s=scope();
    const help=el('admin-portal-scope-help');
    if(help) help.textContent=type==='report'
      ? (s?'Select a student from the selected class.':'Select any active student; report cards remain student-specific.')
      : (s?'Content will be published only to '+s.class_name+' - '+s.section+'.':'All Classes: the same content will be published to every active class/section.');

    if(type==='notice'){
      host.innerHTML='<div class="space-y-2"><input id="admin-portal-notice-title" placeholder="Notice title" class="w-full p-2.5 border rounded-xl text-xs"><textarea id="admin-portal-notice-body" rows="4" placeholder="Notice message" class="w-full p-2.5 border rounded-xl text-xs"></textarea><button type="button" id="admin-portal-save-notice" class="w-full py-2.5 bg-ashiana-green text-white rounded-xl text-xs font-bold">Publish Notice</button></div>';
      el('admin-portal-save-notice').onclick=saveNotice;
    }else if(type==='timetable'){
      host.innerHTML='<div class="grid grid-cols-2 sm:grid-cols-4 gap-2"><select id="admin-portal-day" class="p-2 border rounded-xl text-xs"><option value="1">Monday</option><option value="2">Tuesday</option><option value="3">Wednesday</option><option value="4">Thursday</option><option value="5">Friday</option><option value="6">Saturday</option></select><input id="admin-portal-period" type="number" min="1" max="12" placeholder="Period No." class="p-2 border rounded-xl text-xs"><input id="admin-portal-start" type="time" class="p-2 border rounded-xl text-xs"><input id="admin-portal-end" type="time" class="p-2 border rounded-xl text-xs"></div><div class="grid grid-cols-1 sm:grid-cols-3 gap-2 mt-2"><input id="admin-portal-subject" placeholder="Subject" class="p-2 border rounded-xl text-xs"><input id="admin-portal-teacher" placeholder="Teacher Name" class="p-2 border rounded-xl text-xs"><input id="admin-portal-room" placeholder="Room" class="p-2 border rounded-xl text-xs"></div><button type="button" id="admin-portal-save-timetable" class="w-full mt-2 py-2.5 bg-violet-700 text-white rounded-xl text-xs font-bold">Add Timetable Entry</button>';
      el('admin-portal-save-timetable').onclick=saveTimetable;
    }else if(type==='calendar'){
      host.innerHTML='<div class="space-y-2"><input id="admin-portal-date" type="date" class="w-full p-2.5 border rounded-xl text-xs"><input id="admin-portal-calendar-title" placeholder="Event / Holiday title" class="w-full p-2.5 border rounded-xl text-xs"><textarea id="admin-portal-calendar-body" rows="3" placeholder="Description" class="w-full p-2.5 border rounded-xl text-xs"></textarea><button type="button" id="admin-portal-save-calendar" class="w-full py-2.5 bg-orange-600 text-white rounded-xl text-xs font-bold">Add Calendar Event</button></div>';
      el('admin-portal-save-calendar').onclick=saveCalendar;
    }else{
      host.innerHTML='<div class="space-y-2"><select id="admin-portal-student" class="w-full p-2.5 border rounded-xl text-xs"><option value="">Loading students…</option></select><input id="admin-portal-term" placeholder="Term (e.g. Term 1)" class="w-full p-2.5 border rounded-xl text-xs"><input id="admin-portal-year" value="2026-27" placeholder="Academic Year" class="w-full p-2.5 border rounded-xl text-xs"><textarea id="admin-portal-subjects" rows="5" placeholder="Subjects JSON: [{subject,marks,grade}]" class="w-full p-2.5 border rounded-xl text-[10px] font-mono"></textarea><input id="admin-portal-grade" placeholder="Overall Grade" class="w-full p-2.5 border rounded-xl text-xs"><textarea id="admin-portal-remarks" rows="2" placeholder="Remarks" class="w-full p-2.5 border rounded-xl text-xs"></textarea><label class="text-xs flex items-center gap-2"><input id="admin-portal-published" type="checkbox" checked> Publish to student</label><button type="button" id="admin-portal-save-report" class="w-full py-2.5 bg-cyan-700 text-white rounded-xl text-xs font-bold">Save Report Card</button></div>';
      el('admin-portal-save-report').onclick=saveReport;
      loadStudents();
    }
    loadContent();
  }

  async function saveNotice(){
    if(!ready()) return window.showToast?.('Administrator cloud session is required.','error');
    const title=el('admin-portal-notice-title')?.value.trim(),body=el('admin-portal-notice-body')?.value.trim();
    if(!title||!body) return window.showToast?.('Enter notice title and message.','error');
    const s=scope(),targets=s?[s]:classes;
    if(!targets.length) return window.showToast?.('No active classes found.','error');
    const {error}=await window.supabaseClient.from('student_notices').insert(targets.map(r=>({school_code:window.APS_STUDENT_SCHOOL,class_name:r.class_name,section:r.section,title,body,published_by:window.currentAuthUser.email,active:true})));
    if(error) return window.showToast?.(error.message,'error');
    window.showToast?.('Notice published to '+targets.length+' class'+(targets.length===1?'':'es')+'.','success');loadContent();
  }

  async function saveTimetable(){
    if(!ready()) return window.showToast?.('Administrator cloud session is required.','error');
    const day=Number(el('admin-portal-day')?.value),period=Number(el('admin-portal-period')?.value),subject=el('admin-portal-subject')?.value.trim();
    if(!day||!period||!subject) return window.showToast?.('Complete timetable details.','error');
    const s=scope(),targets=s?[s]:classes;
    if(!targets.length) return window.showToast?.('No active classes found.','error');
    const base={school_code:window.APS_STUDENT_SCHOOL,day_of_week:day,period_no:period,start_time:el('admin-portal-start')?.value||null,end_time:el('admin-portal-end')?.value||null,subject_name:subject,teacher_name:el('admin-portal-teacher')?.value.trim()||null,room:el('admin-portal-room')?.value.trim()||null,active:true,created_by:window.currentAuthUser.email};
    const {error}=await window.supabaseClient.from('student_timetable').insert(targets.map(r=>({...base,class_name:r.class_name,section:r.section})));
    if(error) return window.showToast?.(error.message,'error');
    window.showToast?.('Timetable entry added to '+targets.length+' class'+(targets.length===1?'':'es')+'.','success');loadContent();
  }

  async function saveCalendar(){
    if(!ready()) return window.showToast?.('Administrator cloud session is required.','error');
    const date=el('admin-portal-date')?.value,title=el('admin-portal-calendar-title')?.value.trim(),description=el('admin-portal-calendar-body')?.value.trim();
    if(!date||!title) return window.showToast?.('Enter date and event title.','error');
    const s=scope(),targets=s?[s]:classes;
    if(!targets.length) return window.showToast?.('No active classes found.','error');
    const {error}=await window.supabaseClient.from('student_calendar_events').insert(targets.map(r=>({school_code:window.APS_STUDENT_SCHOOL,event_date:date,title,description:description||null,class_name:r.class_name,section:r.section,created_by:window.currentAuthUser.email,active:true})));
    if(error) return window.showToast?.(error.message,'error');
    window.showToast?.('Calendar event added to '+targets.length+' class'+(targets.length===1?'':'es')+'.','success');loadContent();
  }

  async function saveReport(){
    if(!ready()) return window.showToast?.('Administrator cloud session is required.','error');
    const studentId=el('admin-portal-student')?.value,term=el('admin-portal-term')?.value.trim(),year=el('admin-portal-year')?.value.trim()||'2026-27';
    if(!studentId||!term) return window.showToast?.('Select student and enter term.','error');
    let subjects=[];
    try{subjects=JSON.parse(el('admin-portal-subjects')?.value||'[]');if(!Array.isArray(subjects))throw new Error();}catch(e){return window.showToast?.('Subjects must be a valid JSON array.','error');}
    const {error}=await window.supabaseClient.from('student_report_cards').upsert({school_code:window.APS_STUDENT_SCHOOL,student_id:studentId,academic_year:year,term,subjects,overall_grade:el('admin-portal-grade')?.value.trim()||null,remarks:el('admin-portal-remarks')?.value.trim()||null,published:el('admin-portal-published')?.checked||false,published_by:window.currentAuthUser.email},{onConflict:'school_code,student_id,academic_year,term'});
    if(error) return window.showToast?.(error.message,'error');
    window.showToast?.('Report card saved and reflected in Student Portal.','success');loadContent();
  }

  async function loadContent(){
    const host=el('admin-portal-existing'),type=el('admin-portal-type')?.value||'notice';
    if(!host||!ready()) return;
    const s=scope();
    if(type==='report'){host.innerHTML='<div class="p-3 rounded-xl bg-slate-50 border text-xs text-slate-500">Select a student above to edit their report card.</div>';return;}
    const table=type==='notice'?'student_notices':type==='timetable'?'student_timetable':'student_calendar_events';
    let q=window.supabaseClient.from(table).select('*').eq('school_code',window.APS_STUDENT_SCHOOL).eq('active',true).order('created_at',{ascending:false}).limit(30);
    if(s)q=q.eq('class_name',s.class_name).eq('section',s.section);
    const {data,error}=await q;
    if(error){host.textContent=error.message;return;}
    const rows=data||[];
    host.innerHTML=rows.length?rows.map(r=>{
      const title=escapeText(r.title||r.subject_name||'Timetable Entry');
      const detail=type==='notice'?(r.body||''):type==='calendar'?((r.event_date||'')+' · '+(r.description||'')):('Class '+(r.class_name||'')+'-'+(r.section||'')+' · Period '+(r.period_no||'')+' · '+(r.subject_name||''));
      return '<div class="p-3 mb-2 rounded-xl border bg-white"><div class="font-bold text-xs">'+title+'</div><div class="text-[10px] text-slate-500 mt-1">'+escapeText(detail)+'</div><button type="button" class="mt-2 px-2.5 py-1 rounded-lg bg-rose-50 text-rose-700 text-[10px] font-bold" data-portal-delete="'+escapeText(r.id)+'">Delete</button></div>';
    }).join(''):'<div class="p-4 text-xs text-slate-400 text-center border rounded-xl">No active content for this selection.</div>';
    host.querySelectorAll('[data-portal-delete]').forEach(btn=>btn.addEventListener('click',()=>deleteContent(btn.getAttribute('data-portal-delete'),type)));
  }

  async function deleteContent(id,type){
    if(!id||!ready()) return;
    if(!window.confirm('Delete this student portal item?')) return;
    const table=type==='notice'?'student_notices':type==='timetable'?'student_timetable':'student_calendar_events';
    const {error}=await window.supabaseClient.from(table).update({active:false}).eq('id',id);
    if(error)return window.showToast?.(error.message,'error');
    window.showToast?.('Portal item removed.','success');loadContent();
  }

  function open(){
    const panel=el('admin-tab-student-portal');
    if(!panel) return;
    document.querySelectorAll('[id^="admin-tab-"]').forEach(node=>{node.classList.add('hidden');node.style.display='none';});
    panel.classList.remove('hidden');panel.style.display='';
    loadClasses();render();
    if(window.lucide)window.lucide.createIcons();
  }

  function close(){
    const panel=el('admin-tab-student-portal');
    if(panel){panel.classList.add('hidden');panel.style.display='none';}
  }

  window.openAdminStudentPortal=open;
  window.loadAdminPortalClasses=loadClasses;
  window.renderAdminPortalEditor=render;
  window.loadAdminPortalStudents=loadStudents;

  const original=window.switchAdminTab;
  if(typeof original==='function'){
    window.switchAdminTab=function(tab){
      if(tab==='student-portal'){open();return;}
      close();
      return original(tab);
    };
  }
  document.addEventListener('DOMContentLoaded',function(){
    const cls=el('admin-portal-class'),type=el('admin-portal-type');
    if(cls)cls.addEventListener('change',function(){loadStudents();render();});
    if(type)type.addEventListener('change',render);
  });
})();