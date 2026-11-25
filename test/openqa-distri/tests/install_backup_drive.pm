use Mojo::Base 'basetest';
use LocalHostInstall 'install_system';

# Standalone equivalent of the install-backup-drive plan in main.pm.
sub run {
    install_system(2, 1, 'btrfs', '');
}

sub test_flags {
    return {fatal => 1};
}

1;
