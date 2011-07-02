#!/usr/bin/perl

# standard pragmas
use warnings;
use strict;
use diagnostics;

# Core modules
use English qw( -no_match_vars );
use Carp qw( croak );
use File::Copy;
use File::Path;
use File::Basename;

my ( @rm_dirs, @rm_files ) = ();

my %config_variables = (
    "defaultarch" => qx(dpkg --print-installation-architecture 2>/dev/null)
        || 'i386',
    "nthreads"          => 20,
    "base_path"         => '/var/spool/apt-mirror',
    "mirror_path"       => '$base_path/mirror',
    "skel_path"         => '$base_path/skel',
    "var_path"          => '$base_path/var',
    "cleanscript"       => '$var_path/clean.sh',
    "_contents"         => 1,
    "_autoclean"        => 0,
    "_tilde"            => 0,
    "limit_rate"        => '100m',
    "run_postmirror"    => 1,
    "postmirror_script" => '$var_path/postmirror.sh'
);

my @config_binaries = ();
my @config_sources  = ();

my @index_urls;
my @childrens = ();

my %urls_to_download = ();

my %stat_cache = ();

# --------------------------------------------------------------------------- #
my $unnecessary_bytes = 0;

sub process_directory {
    my $dir             = shift;
    my $local_skipclean = shift;
    my %lsc             = %$local_skipclean;
    my $is_needed       = 0;

    return 1 if $lsc{$dir};

    opendir( my $dir_h, $dir )
        or croak "apt-mirror: Cannot opendir $dir: $ERRNO";
    foreach ( grep { !/^\.$/ && !/^\.\.$/ } readdir($dir_h) ) {
        my $item = $dir . "/" . $_;
        $is_needed |= process_directory( $item, \%lsc )
            if -d $item && !-l $item;
        if ( -f $item ) {
            $is_needed |= process_file( $item, \$unnecessary_bytes );
        }
        $is_needed |= process_symlink($item) if -l $item;
    }
    closedir $dir_h;
    push @rm_dirs, $dir unless $is_needed;
    return $is_needed;
}

# --------------------------------------------------------------------------- #
# round the input number to the nearest tenth
sub round_number {
    my $n = shift;
    my $minus = $n < 0 ? '-' : '';

    $n = abs($n);
    $n = int( ( $n + .05 ) * 10 ) / 10;
    $n .= '.0' unless $n =~ /\./;
    $n .= '0' if substr( $n, ( length($n) - 1 ), 1 ) eq '.';
    chop $n if $n =~ /\.\d\d0$/;
    return "$minus$n";
}

# --------------------------------------------------------------------------- #
sub format_bytes {
    my $bytes     = shift;
    my $bytes_out = '0';
    my $size_name = 'bytes';
    my $KiB       = 1024;
    my $MiB       = 1024 * 1024;
    my $GiB       = 1024 * 1024 * 1024;

    if ( $bytes >= $KiB ) {
        $bytes_out = $bytes / $KiB;
        $size_name = 'KiB';
        if ( $bytes >= $MiB ) {
            $bytes_out = $bytes / $MiB;
            $size_name = 'MiB';
            if ( $bytes >= $GiB ) {
                $bytes_out = $bytes / $GiB;
                $size_name = 'GiB';
            }
        }
    }
    else {
        $bytes_out = $bytes;
        $size_name = 'bytes';
    }

    $bytes_out = round_number($bytes_out);
    return "$bytes_out $size_name";
}

# --------------------------------------------------------------------------- #
sub get_variable {
    my $value = $config_variables{ shift @_ };
    my $count = 16;
    while ( $value =~ s/\$(\w+)/$config_variables{$1}/xg ) {
        croak "apt-mirror: too many substitution while evaluating variable"
            if ( $count-- ) < 0;
    }
    return $value;
}

# --------------------------------------------------------------------------- #
sub lock_aptmirror {
    my $file = get_variable("var_path") . '/apt-mirror.lock';
    open( my $fh, '>>', $file ) || croak "Cannot write $file:$ERRNO";
    close $fh;
    utime undef, undef, $file;
    return;
}

# --------------------------------------------------------------------------- #
sub check_lock {
    if ( -e get_variable("var_path") . "/apt-mirror.lock" ) {
        croak "apt-mirror is already running, exiting";
    }
}

# --------------------------------------------------------------------------- #
sub unlock_aptmirror {
    unlink( get_variable("var_path") . "/apt-mirror.lock" );
    return;
}

# --------------------------------------------------------------------------- #
sub download_urls {
    my $stage = shift;
    my @urls;
    my $i = 0;
    my $pid;
    my $nthreads = get_variable("nthreads");
    local $OUTPUT_AUTOFLUSH = 1;

    @urls = @_;
    $nthreads = @urls if @urls < $nthreads;

    print "Downloading "
        . scalar(@urls)
        . " $stage files using $nthreads threads...\n";

    while ( scalar @urls ) {
        my @part = splice( @urls, 0, int( @urls / $nthreads ) );
        open my $urls_fh, '>', get_variable("var_path") . "/$stage-urls.$i"
            or croak
            "apt-mirror: can't write to intermediate file ($stage-urls.$i)";
        foreach (@part) { print $urls_fh "$_\n"; }
        close $urls_fh
            or croak
            "apt-mirror: can't close intermediate file ($stage-urls.$i)";

        $pid = fork();

        croak "apt-mirror: can't do fork in download_urls" if $pid < 0;

        if ( $pid == 0 ) {
            exec 'wget', '--no-cache',
                '--limit-rate=' . get_variable("limit_rate"),
                '-t', '5', '-r', '-N', '-l', 'inf', '-o',
                get_variable("var_path") . "/$stage-log.$i", '-i',
                get_variable("var_path") . "/$stage-urls.$i";

            # shouldn't reach this unless exec fails
            croak
                "\n\nCould not run wget, please make sure its installed and in your path\n\n";
        }

        push @childrens, $pid;
        $i++;
        $nthreads--;
    }

    print "Begin time: " . localtime() . "\n[" . scalar(@childrens) . "]... ";
    while ( scalar @childrens ) {
        my $dead = wait();
        @childrens = grep { $_ != $dead } @childrens;
        print "[" . scalar(@childrens) . "]... ";
    }
    print "\nEnd time: " . localtime() . "\n\n";
    return;
}

# --------------------------------------------------------------------------- #
sub remove_double_slashes {
    my $token = shift;

    while ( $token =~ s[/\./][/]g )                { }
    while ( $token =~ s[(?<!:)//][/]g )            { }
    while ( $token =~ s[(?<!:/)/[^/]+/\.\./][/]g ) { }
    $token =~ s/~/\%7E/g if get_variable("_tilde");

    return $token;
}

# --------------------------------------------------------------------------- #
sub add_url_to_download {
    my $url = remove_double_slashes(shift);
    $urls_to_download{$url} = shift;
    return;
}

# --------------------------------------------------------------------------- #
sub _stat {
    my ($filename) = shift;

    return @{ $stat_cache{$filename} } if exists $stat_cache{$filename};
    my @res = stat($filename);
    $stat_cache{$filename} = \@res;
    return @res;
}

# --------------------------------------------------------------------------- #
my %skipclean = ();

sub read_config {
    my $cf        = shift;    # config file
    my %clean_dir = ();

    open my $config_file, '<', $cf
        or croak "apt-mirror: can't open config file ($cf)";
    while (<$config_file>) {
        next if /^\s*#/;
        next unless /\S/;
        my @config_line = split;
        my $config_line = shift @config_line;

        if ( $config_line eq "set" ) {
            $config_variables{ $config_line[0] } = $config_line[1];
            next;
        }

        if ( $config_line eq "deb" ) {
            push @config_binaries,
                [ get_variable("defaultarch"), @config_line ];
            next;
        }

        if ( $config_line
            =~ /deb-(alpha|amd64|armel|arm|hppa|hurd-i386|i386|ia64|lpia|m68k|mipsel|mips|powerpc|s390|sh|sparc)/
            )
        {
            push @config_binaries, [ $1, @config_line ];
            next;
        }

        if ( $config_line eq "deb-src" ) {
            push @config_sources, [@config_line];
            next;
        }

        if ( $config_line eq "skip-clean" ) {
            $config_line[0] =~ s[^(\w+)://][];
            $config_line[0] =~ s[/$][];
            $config_line[0] =~ s[~][%7E]g if get_variable("_tilde");
            $skipclean{ $config_line[0] } = 1;
            next;
        }

        if ( $config_line eq "clean" ) {
            $config_line[0] =~ s[^(\w+)://][];
            $config_line[0] =~ s[/$][];
            $config_line[0] =~ s[~][%7E]g if get_variable("_tilde");
            $clean_dir{ $config_line[0] } = 1;
            next;
        }

        croak
            "apt-mirror: invalid line in config file ($INPUT_LINE_NUMBER: $config_line ...)";
    }
    close $config_file;

    croak "Please explicitly specify 'defaultarch' in mirror.list"
        unless get_variable("defaultarch");

    return %clean_dir;
}

# --------------------------------------------------------------------------- #
sub need_update {
    my $filename       = shift;
    my $size_on_server = shift;

    my ( undef, undef, undef, undef, undef, undef, undef, $size )
        = _stat($filename);

    return 1 unless ($size);
    return 0 if $size_on_server == $size;
    return 1;
}

# --------------------------------------------------------------------------- #
sub remove_spaces($) {
    my $hashref = shift;

    foreach ( keys %{$hashref} ) {
        while ( substr( $hashref->{$_}, 0, 1 ) eq ' ' ) {
            substr( $hashref->{$_}, 0, 1 ) = '';
        }
    }
    return;
}

# --------------------------------------------------------------------------- #
sub sanitise_uri {
    my $uri = shift;

    $uri =~ s[^(\w+)://][];
    $uri =~ s/^([^@]+)?@?// if $uri =~ /@/;
    $uri =~ s&:\d+/&/&;                       # and port information
    $uri =~ s/~/\%7E/g if get_variable("_tilde");

    return $uri;
}

# --------------------------------------------------------------------------- #
sub proceed_index_gz {
    my $uri   = shift;
    my $index = shift;
    my ( $path, $package, $mirror, $files ) = '';

    open my $files_all, '>', get_variable("var_path") . "/ALL"
        or croak "apt-mirror: can't write to intermediate file (ALL)";
    open my $files_new, '>', get_variable("var_path") . "/NEW"
        or croak "apt-mirror: can't write to intermediate file (NEW)";
    open my $files_md5, '>', get_variable("var_path") . "/MD5"
        or croak "apt-mirror: can't write to intermediate file (MD5)";

    $path = sanitise_uri($uri);
    local $INPUT_RECORD_SEPARATOR = "\n\n";
    $mirror = get_variable("mirror_path") . "/" . $path;

    if ( $index =~ s/\.gz$// ) {
        system("gunzip < $path/$index.gz > $path/$index");
    }

    open my $stream, '<', "$path/$index"
        or croak "apt-mirror: can't open index in proceed_index_gz";

    while ( $package = <$stream> ) {
        local $INPUT_RECORD_SEPARATOR = "\n";
        chomp $package;
        my ( undef, %lines ) = split( /^([\w\-]+:)/m, $package );

        $lines{"Directory:"} = "" unless defined $lines{"Directory:"};
        chomp(%lines);
        remove_spaces( \%lines );

        if ( exists $lines{"Filename:"} ) {    # Packages index
            $skipclean{ remove_double_slashes(
                    $path . "/" . $lines{"Filename:"} ) } = 1;
            print $files_all remove_double_slashes(
                $path . "/" . $lines{"Filename:"} )
                . "\n";
            print $files_md5 $lines{"MD5sum:"} . "  "
                . remove_double_slashes( $path . "/" . $lines{"Filename:"} )
                . "\n";
            if (need_update(
                    $mirror . "/" . $lines{"Filename:"},
                    $lines{"Size:"}
                )
                )
            {
                print $files_new remove_double_slashes(
                    $uri . "/" . $lines{"Filename:"} )
                    . "\n";
                add_url_to_download( $uri . "/" . $lines{"Filename:"},
                    $lines{"Size:"} );
            }
        }
        else {    # Sources index
            foreach ( split( /\n/, $lines{"Files:"} ) ) {
                next if $_ eq '';
                my @file = split;
                croak "apt-mirror: invalid Sources format" if @file != 3;
                $skipclean{
                    remove_double_slashes(
                        $path . "/" . $lines{"Directory:"} . "/" . $file[2]
                    )
                    }
                    = 1;
                print $files_all remove_double_slashes(
                    $path . "/" . $lines{"Directory:"} . "/" . $file[2] )
                    . "\n";
                print $files_md5 $file[0] . "  "
                    . remove_double_slashes(
                    $path . "/" . $lines{"Directory:"} . "/" . $file[2] )
                    . "\n";
                if (need_update(
                        $mirror . "/" . $lines{"Directory:"} . "/" . $file[2],
                        $file[1]
                    )
                    )
                {
                    print $files_new remove_double_slashes(
                        $uri . "/" . $lines{"Directory:"} . "/" . $file[2] )
                        . "\n";
                    add_url_to_download(
                        $uri . "/" . $lines{"Directory:"} . "/" . $file[2],
                        $file[1] );
                }
            }
        }
    }

    close $files_all;
    close $files_new;
    close $files_md5;

    close $stream;
    return;
}

# --------------------------------------------------------------------------- #
sub copy_file {
    my ( $from, $to ) = @_;
    my $dir = dirname($to);
    return unless -f $from;
    mkpath($dir) unless -d $dir;
    unless ( copy( $from, $to ) ) {
        warn("apt-mirror: can't copy $from to $to");
        return;
    }
    my ( $atime, $mtime ) = ( stat($from) )[ 8, 9 ];
    utime( $atime, $mtime, $to ) or croak "apt-mirror: can't utime $to";
    return;
}

# --------------------------------------------------------------------------- #
sub process_symlink {
    return 1;    # symlinks are always needed
}

# --------------------------------------------------------------------------- #
sub process_file {
    my $file        = shift;
    my $extra_bytes = shift;

    $file =~ s[~][%7E]g if get_variable("_tilde");
    return 1 if $skipclean{$file};
    push @rm_files, sanitise_uri($file);
    my (undef, undef, undef, undef, undef, undef, undef,
        $size, undef, undef, undef, undef, $blocks
    ) = stat($file);
    $extra_bytes += $blocks * 512;
    return 0;
}

# --------------------------------------------------------------------------- #
# --------------------------------------------------------------------------- #

#handling command line arguments.
#this needs updating -kk
my $config_file = "/etc/apt/mirror.list";    # Default value
if ( $_ = shift ) {
    croak "apt-mirror: invalid config file specified" unless -f $_;
    $config_file = $_;
}

chomp $config_variables{"defaultarch"};

##############################################################################
## Parse config

my %clean_directory = read_config($config_file);

## Create the 3 needed directories if they don't exist yet
my @needed_directories = (
    get_variable("mirror_path"),
    get_variable("skel_path"),
    get_variable("var_path")
);
foreach my $needed_directory (@needed_directories) {
    unless ( -d $needed_directory ) {
        mkdir($needed_directory)
            or
            cluck("apt-mirror: can't create $needed_directory dir. $ERRNO");
    }
}

check_lock();

local $SIG{INT}  = "unlock_aptmirror";
local $SIG{HUP}  = "unlock_aptmirror";
local $SIG{TERM} = "unlock_aptmirror";

lock_aptmirror();

######################################################################################
## Skel download

my ( $url, $arch );

foreach (@config_sources) {
    my ( $uri, $distribution, @components ) = @{$_};

    if (@components) {
        $url = $uri . "/dists/" . $distribution . "/";

        add_url_to_download( $url . "Release" );
        add_url_to_download( $url . "Release.gpg" );
        foreach (@components) {
            add_url_to_download( $url . $_ . "/source/Release" );
            add_url_to_download( $url . $_ . "/source/Sources.gz" );
            add_url_to_download( $url . $_ . "/source/Sources.bz2" );
        }
    }
    else {
        add_url_to_download( $uri . "/$distribution/Release" );
        add_url_to_download( $uri . "/$distribution/Release.gpg" );
        add_url_to_download( $uri . "/$distribution/Sources.gz" );
        add_url_to_download( $uri . "/$distribution/Sources.bz2" );
    }
}

foreach (@config_binaries) {
    my ( $archi, $uri, $distribution, @components ) = @{$_};

    if (@components) {
        $url = $uri . "/dists/" . $distribution . "/";

        add_url_to_download( $url . "Release" );
        add_url_to_download( $url . "Release.gpg" );
        if ( get_variable("_contents") ) {
            add_url_to_download( $url . "Contents-" . $archi . ".gz" );
            add_url_to_download( $url . "Contents-" . $archi . ".bz2" );
        }
        foreach (@components) {
            add_url_to_download(
                $url . $_ . "/binary-" . $archi . "/Release" );
            add_url_to_download(
                $url . $_ . "/binary-" . $archi . "/Packages.gz" );
            add_url_to_download(
                $url . $_ . "/binary-" . $archi . "/Packages.bz2" );
        }
    }
    else {
        add_url_to_download( $uri . "/$distribution/Release" );
        add_url_to_download( $uri . "/$distribution/Release.gpg" );
        add_url_to_download( $uri . "/$distribution/Packages.gz" );
        add_url_to_download( $uri . "/$distribution/Packages.bz2" );
    }
}

chdir get_variable("skel_path") or croak "apt-mirror: can't chdir to skel";
@index_urls = sort keys %urls_to_download;
download_urls( "index", @index_urls );

foreach ( keys %urls_to_download ) {
    s[^(\w+)://][];
    s[~][%7E]g if get_variable("_tilde");
    $skipclean{$_} = 1;
    $skipclean{$_} = 1 if s[\.gz$][];
    $skipclean{$_} = 1 if s[\.bz2$][];
}

######################################################################################
## Main download prepair

%urls_to_download = ();

print "Proceed indexes: [";

foreach (@config_sources) {
    my ( $uri, $distribution, @components ) = @{$_};
    print "S";
    if (@components) {
        foreach my $component (@components) {
            proceed_index_gz( $uri,
                "/dists/$distribution/$component/source/Sources.gz" );
        }
    }
    else {
        proceed_index_gz( $uri, "/$distribution/Sources.gz" );
    }
}

foreach (@config_binaries) {
    my ( $archi, $uri, $distribution, @components ) = @{$_};
    print "P";
    if (@components) {
        foreach my $comp (@components) {
            proceed_index_gz( $uri,
                "/dists/$distribution/$comp/binary-$archi/Packages.gz" );
        }
    }
    else {
        proceed_index_gz( $uri, "/$distribution/Packages.gz" );
    }
}

#clear stat_cache
%stat_cache = ();

print "]\n\n";

######################################################################################
## Main download

chdir get_variable("mirror_path")
    or croak "apt-mirror: can't chdir to mirror";

my $need_bytes = 0;
foreach ( values %urls_to_download ) {
    $need_bytes += $_;
}

my $size_output = format_bytes($need_bytes);

print "$size_output will be downloaded into archive.\n";

download_urls( "archive", sort keys %urls_to_download );

######################################################################################
## Copy skel to main archive

foreach (@index_urls) {
    croak "apt-mirror: invalid url in index_urls" unless s[^(\w+)://][];
    copy_file(
        get_variable("skel_path") . "/" . sanitise_uri("$_"),
        get_variable("mirror_path") . "/" . sanitise_uri("$_")
    );
    copy_file(
        get_variable("skel_path") . "/" . sanitise_uri("$_"),
        get_variable("mirror_path") . "/" . sanitise_uri("$_")
    ) if (s/\.gz$//);
    copy_file(
        get_variable("skel_path") . "/" . sanitise_uri("$_"),
        get_variable("mirror_path") . "/" . sanitise_uri("$_")
    ) if (s/\.bz2$//);
}

######################################################################################
## Make cleaning script

chdir get_variable("mirror_path")
    or croak "apt-mirror: can't chdir to mirror";

foreach ( keys %clean_directory ) {
    process_directory( $_, \%skipclean ) if -d $_ && !-l $_;
}

open my $clean_script, '>', get_variable("cleanscript")
    or croak "apt-mirror: can't open clean script file";

my ( $i, $total ) = ( 0, scalar @rm_files );

if ( get_variable("_autoclean") ) {

    print format_bytes($unnecessary_bytes), "in $total files and ",
        scalar(@rm_dirs), " directories will be freed...";

    chdir get_variable("mirror_path")
        or croak "apt-mirror: can't chdir to mirror";

    foreach (@rm_files) { unlink $_; }
    foreach (@rm_dirs)  { rmdir $_; }

}
else {

    print format_bytes($unnecessary_bytes), "in $total files and ",
        scalar(@rm_dirs), " directories can be freed.\n";
    print "Run " . get_variable("cleanscript") . " for this purpose.\n\n";

    print $clean_script "cd "
        . get_variable("mirror_path")
        . " || exit 1\n\n";
    print $clean_script
        "echo 'Removing $total unnecessary files [$unnecessary_bytes bytes]...'\n";
    foreach (@rm_files) {
        print $clean_script "rm -f '$_'\n";
        print $clean_script "echo -n '[" . int( 100 * $i / $total ) . "\%]'\n"
            unless $i % 500;
        print $clean_script "echo -n .\n" unless $i % 10;
        $i++;
    }
    print $clean_script "echo 'done.'\n";
    print $clean_script "echo\n\n";

    $i     = 0;
    $total = scalar @rm_dirs;
    print $clean_script "echo 'Removing $total unnecessary directories...'\n";
    foreach (@rm_dirs) {
        print $clean_script "rmdir '$_'\n";
        print $clean_script "echo -n '[" . int( 100 * $i / $total ) . "\%]'\n"
            unless $i % 50;
        print $clean_script "echo -n .\n";
        $i++;
    }
    print $clean_script "echo 'done.'\n";
    print $clean_script "echo\n";

}

close $clean_script;

if ( get_variable("run_postmirror") ) {
    print "Running the Post Mirror script ...\n";
    print "(" . get_variable("postmirror_script") . ")\n\n";
    if ( -x get_variable("postmirror_script") ) {
        system( get_variable("postmirror_script") );
    }
    else {
        system( '/bin/sh ' . get_variable('postmirror_script') );
    }
    print
        "\nPost Mirror script has completed. See above output for any possible errors.\n\n";
}

unlock_aptmirror();

__END__

#-----------------------------------------------------------------------------

=pod

=head1 NAME

apt-mirror-fork (apt-mirror.pl) - apt sources mirroring tool

=head1 SYNOPSIS

apt-mirror.pl [configfile]

=head1 DESCRIPTION

A small and efficient tool that lets you mirror a part of or
the whole Debian GNU/Linux distribution or any other apt sources.

Main features:
 * It uses a config similar to apts F<sources.list>
 * It's fully pool comply
 * It supports multithreaded downloading
 * It supports multiple architectures at the same time
 * It can automatically remove unneeded files
 * It works well on overloaded channel to internet
 * It never produces an inconsistent mirror including while mirroring
 * It works on all POSIX compliant systems with perl and wget

=head1 COMMENTS

apt-mirror uses F</etc/apt/mirror.list> as a configuration file.
By default it is tuned to official Debian or Ubuntu mirrors. Change
it for your needs.

After you setup the configuration file you may run as root:

    # su - apt-mirror.pl -c apt-mirror

Or uncomment line in F</etc/cron.d/apt-mirror> to enable daily mirror updates.

=head1 FILES

F</etc/apt/mirror.list>
        Main configuration file

F</etc/cron.d/apt-mirror>
        Cron configuration template

F</var/spool/apt-mirror/mirror>
        Mirror places here

F</var/spool/apt-mirror/skel>
        Place for temporarily downloaded indexes

F</var/spool/apt-mirror/var>
        Log files placed here. URLs and MD5 summs also here.

=head1 CONFIGURATION EXAMPLES

The mirror.list configuration supports many options, the file is well commented explinging each option.
here are some sample mirror configuration lines showing the various supported ways :

Normal:
deb http://example.com/debian stable main contrib non-free

Arch Specific: ( many other arch's are supported )
deb-powerpc http://example.com/debian stable main contrib non-free

HTTP and FTP Auth or non-standard port:
deb http://user:pass@example.com:8080/debian stable main contrib non-free

Source Mirroring:
deb-src http://example.com/debian stable main contrib non-free

=head1 AUTHOR

Kirk Kimmel E<lt> kimmel.k.programmer [at] gmail.com E<gt>

=head1 FORMER AUTHORS

Dmitry N. Hramtsov E<lt>hdn@nsu.ruE<gt> (Original author)
Brandon Holtsclaw E<lt>me@brandonholtsclaw.comE<gt>

=head1 LICENSE AND COPYRIGHT

This application is licensed under the GNU General Public License (GPL) Version 3. LICENSE.txt contains a copy of the GPL v3.

=cut

