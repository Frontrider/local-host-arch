use Mojo::Base 'basetest';
use testapi;

# The live session autologins into i3, which starts Calamares as root. There is
# no desktop step to wait for: the installer is the first window and fills the
# workspace, so its welcome page is what boot has to reach.

sub run {
    # Boot the default entry immediately. If GRUB has already timed out (or
    # the ISO skips it), accept the welcome page without pressing Enter there.
    assert_screen(['grub-open-source', 'welcome-language'], 900);
    return if match_has_tag('welcome-language');

    send_key 'ret';
    assert_screen('welcome-language', 900);
}

sub test_flags {
    return {fatal => 1};
}

1;
