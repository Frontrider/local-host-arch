package LocalHostStorage;

use strict;
use warnings;
use Exporter 'import';
use testapi;

our @EXPORT_OK = qw(verify_storage);

sub verify_storage {
    my ($disks, $backup, $backup_fs, $raid) = @_;
    my $data_disks = $disks - $backup;
    my $serial = "/dev/$testapi::serialdev";

    assert_screen('installed-desktop', 900);
    wait_screen_change(sub { send_key 'super-t'; }, 30)
        or die "the installed system did not open a terminal";
    sleep 3;

    my $commands = 'echo FSTAB_BEGIN; cat /etc/fstab; echo FSTAB_END; ';
    if ($raid ne '') {
        # The fstab degraded option is not proof of the filesystem profile.
        # Require /data itself to be mounted before asking Btrfs about it.
        $commands .= 'findmnt -n -M /data -t btrfs; '
            . 'btrfs filesystem df /data; btrfs filesystem show /data; ';
    }
    $commands .= 'echo STORAGE_END';
    enter_cmd("echo openqa | sudo -S sh -ec '{ $commands; } > $serial 2>&1'", secret => 1);

    my $output = wait_serial(qr/^STORAGE_END\r?$/m, timeout => 60);
    die "could not read installed storage configuration from the serial console"
        unless defined $output;
    my ($fstab, $details) = $output =~ /^FSTAB_BEGIN\r?\n(.*?)^FSTAB_END\r?\n(.*)^STORAGE_END\r?$/ms;
    die "storage markers were not captured:\n$output" unless defined $fstab;
    record_info('fstab', $fstab);

    my %mounts;
    for my $line (split /\n/, $fstab) {
        next if $line =~ /^\s*(?:#|$)/;
        my ($device, $target, $fs, $options) = split ' ', $line;
        next unless defined $target && ($target eq '/' || $target eq '/data' || $target eq '/backups');
        die "duplicate $target entry in fstab:\n$fstab" if exists $mounts{$target};
        $mounts{$target} = [$device, $fs // '', $options // ''];
    }

    my %seen;
    for my $expected (['/', 'btrfs'], ['/data', $data_disks ? 'btrfs' : ''],
        ['/backups', $backup ? $backup_fs : '']) {
        my ($target, $fs) = @$expected;
        my $entry = $mounts{$target};
        if ($fs eq '') {
            die "unexpected $target entry in fstab:\n$fstab" if $entry;
            next;
        }
        die "no $target entry in fstab:\n$fstab" unless $entry;
        my ($device, $actual_fs, $options) = @$entry;
        die "$target is $actual_fs, expected $fs:\n$fstab" unless $actual_fs eq $fs;
        die "$target does not use a distinct UUID:\n$fstab"
            unless $device =~ /^UUID=\S+$/ && !$seen{lc $device}++;
        my %opts = map { $_ => 1 } split /,/, $options;
        next if $target eq '/';

        die "$target is missing nofail:\n$fstab" unless $opts{nofail};
        if ($target eq '/backups') {
            die "$target is missing noauto:\n$fstab" unless $opts{noauto};
        }
        else {
            die "/data should mount automatically:\n$fstab" if $opts{noauto};
            die "/data degraded option does not match RAID plan:\n$fstab"
                if ($opts{degraded} // 0) != ($raid eq 'RAID1' ? 1 : 0);
        }
    }

    if ($raid ne '') {
        record_info('Btrfs /data', $details);
        for my $kind ('Data', 'Metadata') {
            die "$kind is not using $raid on /data:\n$details"
                unless $details =~ /^\Q$kind\E,\s*\Q$raid\E:/mi;
        }
        die "/data does not have $data_disks Btrfs devices:\n$details"
            unless $details =~ /^\s*Total devices\s+\Q$data_disks\E\b/mi;
    }
}

1;
