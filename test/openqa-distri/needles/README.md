# Needles

os-autoinst finds a screen by matching a needle against a screenshot from the
job. A needle is `<name>.json` plus `<name>.png`:

- `tags` are the names `assert_screen` / `assert_and_click` wait for;
- `area` is the rectangle inside the PNG that has to match;
- `click_point` is where a click lands, relative to that rectangle.

This directory is bind-mounted into the openQA container at
`/var/lib/openqa/share/tests/local-host/needles`, so the checked-in needles are
used directly and a needle saved in the editor lands here.

Measure each rectangle against its paired `<tag>.png`. Reference captures
in `../screenshots/` can show a different window layout.

The Calamares sidebar is display-only. Assert page content, not sidebar
steps. Use disabled controls and GRUB entries only with `assert_screen`.

## Backup fixtures

Keep the JSON and PNG for each test reference together in this directory.
The install tests verify backup-drive assignment by matching the “Backup
filesystem” heading, not the disk name from the reference capture.

Reuse `review-storage-{back,next,cancel}` or `calamares-{back,next,cancel}`
for navigation. The remote selector needles match the dropdown while it is
closed; the open menu and below-the-fold FTP controls still need captures.

## Recording more

1. Run a job. It fails at the first `assert_screen` and keeps the screenshot.
2. Open <http://localhost:1080>, click the job, then the failed module
   (for example `boot_to_desktop`).
3. Above the screenshot click **Create new needle**. The needle editor opens
   with the screenshot and a selection area.
4. Set **Name** to the tag the test waits for, drag a small rectangle over a
   stable part of the screen, leave the match threshold as it is, and click
   **Save**.
5. Click **Restart job**. The next missing tag fails, and you repeat from 3.

Because the needles directory is bind-mounted, a needle saved this way is
already in this directory. The openQA user inside the container may own it;
take it back with:

```bash
sudo chown -R "$(id -u):$(id -g)" test/openqa-distri/needles
```

Keep each match small and specific: one title, one button, one row. A needle
that matches a whole window matches the wrong page sooner or later.
