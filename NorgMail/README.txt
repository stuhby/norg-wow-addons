NorgMail
========

Takes every attachment and every money mail out of your mailbox, one at a time,
at a pace the server accepts.

  /mail          take everything
  /mail money    take only the money, leave attachments
  /mail stop     abort a run
  Take All       button on the inbox frame

WHAT IT WILL NOT DO
-------------------
C.O.D. mail is ALWAYS skipped. TakeInboxItem() on a C.O.D. mail pays it with no
confirmation, so auto-taking those would quietly spend your gold. They are counted
and reported so you can open them deliberately.

It stops when your bags are full and tells you, rather than hammering a mailbox
that cannot accept anything.

WHY IT IS SLOW ON PURPOSE
-------------------------
Taking an attachment removes it server-side and the whole inbox is re-sent, so
indices shift underneath you. The addon therefore re-scans from the top after
every single action instead of looping over a range -- looping while mutating is
how these addons skip mail without telling you. A third of a second between
actions is not politeness; firing faster gets requests rejected against stale
indices and items are silently left behind.
