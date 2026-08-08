# Documentation screenshots

These images must be captured from the synthetic documentation mode, never
from a normal app session. The mode uses temporary stores and does not load
saved dictations, credentials, reference folders, audio devices, or process
names.

Build the app, then launch one mode at a time:

```sh
./scripts/build-app.sh debug
open -n .build/PermanentUnderclass.app --args --documentation-demo=quick-dictation
open -n .build/PermanentUnderclass.app --args --documentation-demo=meeting
open -n .build/PermanentUnderclass.app --args --documentation-demo=interview
```

Capture only the app window, with the macOS window shadow disabled, and write
the images to `quick-dictation.png`, `meeting.png`, and `interview.png` in this
directory. Quit each documentation-mode copy after capture. The Quick
Dictation window is intentionally shorter because its synthetic history has
only three entries.
