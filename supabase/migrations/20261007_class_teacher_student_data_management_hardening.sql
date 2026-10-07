revoke execute on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text) from anon;
revoke execute on function public.teacher_delete_student(uuid) from anon;
grant execute on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text) to authenticated;
grant execute on function public.teacher_delete_student(uuid) to authenticated;