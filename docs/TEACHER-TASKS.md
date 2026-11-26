# Teacher task assignment and progress tracking

## How it works

- An administrator opens **Staff Tasks**, selects one active teacher or staff member, enters a title and instructions, and sets a deadline.
- A teacher or staff member opens **My Tasks** in the staff menu to review assignments and post progress as **Not started**, **In progress**, **Blocked**, or **Completed**, with a percentage and optional note.
- Progress updates are append-only, so the administrator can review the recent update history as well as the current status.
- The administrator task board and staff task list subscribe to Supabase Realtime. The staff task list also refreshes on sign-in, so assignments remain visible if the assignee was offline when assigned.
- Active staff with an email appear in the assignment selector. Database RLS restricts reads to administrators and the assigned account; only administrators can create or edit task assignments, and assignees can only add progress updates for their own tasks.

## Rollout

The database migration has been applied to the connected Ashiana Supabase project. The task board now loads there. To make the updated interface available to everyone:

1. Deploy the updated website/PWA if it is not already live. Rebuild and distribute the Android app only if the packaged frontend must be updated immediately.
2. Sign in as an administrator and assign a task to a teacher or staff account.
3. Sign in as that assignee, open **My Tasks**, and post a progress update. With both boards open, confirm the administrator view changes live and the update appears in history.
4. Confirm a different staff account cannot read the task or post updates for it.

The migration creates task tables, RLS policies, indexes, an update timestamp trigger, enables the Tasks role permission for teachers and staff, and adds both task tables to the existing `supabase_realtime` publication. It does not create assignments or modify existing school records.
