package LocalHostGuest;

use strict;
use warnings;
use Exporter 'import';
use MIME::Base64 qw(encode_base64);
use testapi;

our @EXPORT_OK = qw(run_guest_check);

sub run_guest_check {
    my ($file, $title, $timeout, @args) = @_;
    my $script = get_test_data($file) // die "missing guest check: $file";
    my $encoded = encode_base64($script);
    my $serial = "/dev/$testapi::serialdev";
    my $arguments = join '', map {
        die "unsafe guest check argument" unless /\A[A-Za-z0-9._~-]+\z/;
        " '$_'"
    } @args;

    # Reuse the terminal opened by verify_extra_disks. Send the script in
    # short lines without relying on guest network access for the transfer.
    enter_cmd("openqa_guest_script=\$(cat <<'OPENQA_GUEST_SCRIPT'\n"
        . $encoded . "OPENQA_GUEST_SCRIPT\n)", max_interval => 25);
    # The serial device is root-only; keep the redirection inside sudo.
    my $command = q{echo openqa | sudo -S bash -o pipefail -c '}
        . "{ payload=\$1; shift; printf %s \"\$payload\" | base64 -d | bash -s -- \"\$@\"; "
        . "rc=\$?; echo OPENQA_GUEST_CHECK_RESULT=\"\$rc\"; } > $serial 2>&1"
        . q{' _ "$openqa_guest_script"} . $arguments;
    enter_cmd($command, secret => 1);

    my $result = wait_serial(qr/^OPENQA_GUEST_CHECK_RESULT=\d+\r?$/m, timeout => $timeout);
    die "no result from $title" unless defined $result;
    record_info($title, $result);
    die "$title failed:\n$result"
        unless $result =~ /^OPENQA_GUEST_CHECK_RESULT=0\r?$/m;
}

1;
