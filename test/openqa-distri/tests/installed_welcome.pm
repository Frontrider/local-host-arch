use Mojo::Base 'basetest';
use testapi;

# The Users page enabled autologin. The installed system must therefore reach
# the installed i3 desktop without a LightDM prompt. Matching the installed bar
# (no Installer button) also proves the VM booted the installed disk instead of
# the ISO again. If autologin was not applied, the LightDM greeter stays up and
# this check fails at the greeter rather than being masked by a manual login.

sub run {
    assert_screen('installed-desktop', 900);
}

sub test_flags {
    return {fatal => 1};
}

1;
