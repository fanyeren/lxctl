package Lxctl::migrate;

use strict;
use warnings;

use Getopt::Long;
use Lxc::object;
use LxctlHelpers::config;
use LxctlHelpers::SSH;

my %options = ();

my $yaml_conf_dir;
my $lxc_conf_dir;
my $root_mount_path;
my $templates_path;
my $vg;

my $ssh;

my $rsync_opts;
my $config;

sub migrate_get_opt
{
    my $self = shift;

    GetOptions(\%options, 
        'rootsz=s',  'tohost=s', 'remuser=s', 'remport=s', 'remname=s', 'afterstart!', 'delete!', 'clone!', 'continue!');

    $options{'remuser'} ||= 'root';
    $options{'remport'} ||= '22';
    $options{'remname'} ||= $options{'contname'};
    $options{'afterstart'} ||= 1;
    $options{'delete'} ||= 0;
    $options{'clone'} ||= 0;
    $options{'continue'} ||= 0;

    if ($options{'clone'}) {
        $options{'afterstart'} = 0;
        $options{'delete'} = 0;
        if ($options{'remname'} eq $options{'contname'}) {
            die "Specify --remname not equal to container name for cloning";
        }
    }

    defined($options{'tohost'}) or 
        die "To which host should I migrate?\n\n";

    $ssh = LxctlHelpers::SSH->connect($options{'tohost'}, $options{'remuser'}, $options{'remport'});
}

sub check_mount_and_mount
{
	my $sefl = shift;
        my $vm_option_ref;
        my %vm_options;
        $vm_option_ref = $config->load_file("$yaml_conf_dir/$options{'contname'}.yaml");
        %vm_options = %$vm_option_ref;

        my $mount_result = `mount`;
        # mount root
        if (!defined($vm_options{'rootsz'}) || $vm_options{'rootsz'} ne 'share') {
                my $mp_ref = $vm_options{'rootfs_mp'};
                my %mp = %$mp_ref;
                if ($mount_result !~ m/on $mp{'to'}/) {
                        print "Mount rootfs for migrate\n";
                        (system("mount -t $mp{'fs'} -o $mp{'opts'} $mp{'from'} $mp{'to'}") == 0) or die "Failed to mount $mp{'from'} to $mp{'to'}\n\n";
                }
        }
}

sub unmount_cont
{
	my $self = shift;
	my $vm_option_ref = $config->load_file("$yaml_conf_dir/$options{'contname'}.yaml");
	my %vm_options = %$vm_option_ref;

	my $mount_result = `mount`;
	my $mp_ref = $vm_options{'rootfs_mp'};
	my %mp = %$mp_ref;
	if ($mount_result =~ m/on $mp{'to'}/) {
		print "Unmount rootfs after migrate\n";
		(system("umount $mp{'to'}") == 0) or print "Failed to unmount $mp{'to'}\n\n";
	}
}
	

sub re_rsync
{
    my $self = shift;
    my $first_pass = shift;
    my $status;

    eval {
        $status = $self->{'lxc'}->status($options{'contname'});
    } or do {
        die "Failed to get status for container $options{'contname'}!\n\n";
    };

    if ($status eq 'RUNNING') {
        eval {
            print "Stopping container $options{'contname'}...\n";
            $self->{'lxc'}->stop($options{'contname'});
        } or do {
            die "Failed to stop container $options{'contname'}.\n\n";
        };
    } else {
        return if $first_pass;
        print "WARNING: container $options{'contname'} was already stopped.\n\n";
    };

    print "Start second rsync pass...\n";
    $self->sync_data()
        or die "Failed to finish second rsinc pass.\n\n";
}

sub copy_config
{
    my $self = shift;

    print "Sending config to $options{'tohost'}...\n";

    $ssh->put_file("$yaml_conf_dir/$options{'contname'}.yaml", "/tmp/$options{'contname'}.yaml");
    $ssh->execute("sed -i.bak 's/$options{'contname'}/$options{'remname'}/g' '/tmp/$options{'contname'}.yaml'");
}

sub sync_data {
    my $self = shift;

    $rsync_opts = $config->get_option_from_main('rsync', 'RSYNC_OPTS');
    my $rsync_from = "$root_mount_path/$options{'contname'}/";
    my $rsync_to = "$options{'remuser'}\@$options{'tohost'}:$root_mount_path/$options{'remname'}/";
    my $ret = !system("rsync $rsync_opts $rsync_from $rsync_to")
        or print "There were some problems during syncing root filesystem. It's ok if this is the first pass.\n\n";

    return $ret;
}

sub remote_deploy
{
    my $self = shift;
    my $first_pass;

    if ($options{'continue'} == 0) {

        $self->copy_config();

        print "Creating remote container...\n";

        $ssh->execute("lxctl create $options{'remname'} --empty --load /tmp/$options{'contname'}.yaml")
            or die "Failed to create remote container.\n\n";

        print "Start first rsync pass...\n";
        $first_pass = $self->sync_data();
    } else {
        $first_pass = 0;
    };

    $self->re_rsync($first_pass);

    eval {
        #Next line is a very ugly and useful only for us hack. Don't pay any attention to it.
        $ssh->execute("ls /usr/share/perl5/Lxctl/conduct.pm 1>/dev/null 2>/dev/null && lxctl conduct $options{'remname'}");
    } or do {
        print "Meow...\n";
    };

    if ($options{'afterstart'} != 0) {
        print "Starting remote container...\n";
        $ssh->execute("lxctl start $options{'remname'}")
            or die "Failed to start remote container!\n\n";
    }

    if ($options{'delete'} != 0) {
        eval {
            $ssh->execute("if [[ \$(lxctl list | grep $options{'remname'} | awk '{print \$3}') -ne running ]]; then exit 1; else exit 0; fi")
        } or do {
            print "Remote container was not started. I won't delete local.\n";
            return;
        };
        print "Destroying container $options{'contname'}...\n";
        system("lxctl destroy $options{'contname'} -f");
    }
}

# Ugly hack. Will not work with non standard paths.
sub clone
{
    my $self = shift;

    eval {
        $ssh->execute("echo -n '$options{'remname'}' > /var/lxc/root/$options{'remname'}/rootfs/etc/hostname");
        $ssh->execute("sed -i.bak 's/$options{'contname'}/$options{'remname'}/g' /var/lxc/root/$options{'remname'}/rootfs/etc/hosts");
    } or do {
        print "Hostname or /etc/hosts mau be incorrect, somthing failed.\n";
    };
}

sub do
{
    my $self = shift;

    $options{'contname'} = shift
        or die "Name the container please!\n\n";

    $self->migrate_get_opt();
    $self->check_mount_and_mount();
    $self->remote_deploy();
    if ($options{'clone'}) {
        $self->clone();
        system("lxctl start $options{'contname'}");
    } else {
        $ssh->put_file("$lxc_conf_dir/$options{'contname'}/config", "$lxc_conf_dir/$options{'contname'}/config");
        system("lxctl set $options{'contname'} --autostart 0");
    	$self->unmount_cont();
    }
}

sub new
{
    my $class = shift;
    my $self = {};
    bless $self, $class;
    $self->{lxc} = new Lxc::object;

    $root_mount_path = $self->{'lxc'}->get_roots_path();
    $templates_path = $self->{'lxc'}->get_template_path();
    $yaml_conf_dir = $self->{'lxc'}->get_config_path();
    $lxc_conf_dir = $self->{'lxc'}->get_lxc_conf_dir();
    $config = new LxctlHelpers::config;

    return $self;
}

1;
__END__

=head1 AUTHOR

Anatoly Burtsev, E<lt>anatolyburtsev@yandex.ruE<gt>
Pavel Potapenkov, E<lt>ppotapenkov@gmail.comE<gt>
Vladimir Smirnov, E<lt>civil.over@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Anatoly Burtsev, Pavel Potapenkov, Vladimir Smirnov

This library is free software; you can redistribute it and/or modify
it under the same terms of GPL v2 or later, or, at your opinion
under terms of artistic license.

=cut
