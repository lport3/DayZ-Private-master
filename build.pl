#!/usr/bin/perl -w

use Getopt::Long qw(:config pass_through);

use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Slurp;
use File::Basename;
use File::DirCompare;

use Text::Diff;
use Text::Patch;

use Digest::SHA1 qw(sha1_hex);
use Time::HiRes qw(time);
use List::Util qw(max min);

our %args;
GetOptions(
	\%args,
	'world|w|map|mission|m=s',
	'instance|id|i=s',
	'list',
	'clean',
	'help'
);

# Set defaults if options are not specified
$args{'world'} = ($args{'world'}) ? lc($args{'world'}) : 'chernarus';
$args{'instance'} = '1' unless $args{'instance'};

# Initialize paths
my $base_dir = dirname(__FILE__);
my $tmp_dir  = "$base_dir/tmp";
my $wld_dir  = "$base_dir/pkg/world";
my $bls_dir  = "$base_dir/pkg/bliss";
my $msn_dir  = "$base_dir/mission";
my $src_dir  = "$base_dir/util/dayz_server";
my $dst_dir  = "$base_dir/deploy";

my $build_dir     = "$tmp_dir/dayz_server";
my $msn_build_dir = "$tmp_dir/mission_tmp";
my $pkg_build_dir = "$tmp_dir/package_tmp";

if ($args{'help'}) {
	print "usage: build.pl [--world <world>] [--instance <id>] [--with-<option>] [--clean] [--list]\n";
	print "    --world <world>: build an instance for the specified map/world\n";
	print "    --instance <id>: build an instance with the specified integer instance id\n";
	print "\n";
	print "    --with-<package>: merge in changes from ./pkg/<package>/ during build\n";
	print "    --clean: remove all files in ./tmp/ and perform no further action\n";
	print "    --list: lists all available worlds and packages\n";
	exit;
} elsif ($args{'list'}) {
	opendir (my $dh, "$msn_dir/world");
	my @missions = readdir $dh;
	closedir $dh;

	print "Available worlds:\n";
	foreach my $world (@missions) {
		print "    $world\n" unless ($world =~ m/^\./);
	}
	print "\n";

	opendir $dh, "$base_dir/pkg";
	my @pkgs = readdir $dh;
	closedir $dh;

	print "Available options:\n";
	foreach my $pkg (@pkgs) {
		print "    --with-$pkg\n" unless ($pkg =~ m/(^\.|world|bliss)/);
	}
	exit;
} elsif ($args{'clean'}) {
	print "INFO: Removing $dst_dir\n";
	remove_tree($dst_dir);
	print "INFO: Removing $tmp_dir\n";
	remove_tree($tmp_dir);
	exit;
}

die "FATAL: Source dir $src_dir does not exist\n" unless (-d $src_dir);
die "FATAL: Mission dir $base_dir/mission/world/$args{'world'} does not exist\n" unless (-d "$base_dir/mission/world/$args{'world'}");

# Create deploy directory and get build paths ready
copy_dir("$base_dir/util/deploy", $dst_dir) unless (-d $dst_dir);
make_path($tmp_dir) unless (-d $tmp_dir);

# Do all modifications to deploy directory
configure_deploy(
	$args{'instance'},
	$args{'world'},
	"$base_dir/util/server.bat",
	"$base_dir/util/dayz_config",
	$dst_dir
);

# Clean up existing temp directories before starting work
remove_tree($build_dir) if (-d $build_dir);
remove_tree($pkg_build_dir) if (-d $pkg_build_dir);
remove_tree($msn_build_dir) if (-d $msn_build_dir);

# Apply core Bliss changes to build directory
print "INFO: Merging Bliss code into official server\n";
copy_dir($src_dir, $build_dir);
simple_merge($bls_dir, $build_dir);

# Optionally merge in world-specific modifications
if (-d "$wld_dir/$args{'world'}") {
	print "INFO: Merging changes for world $args{'world'}\n";
	simple_merge("$wld_dir/$args{'world'}", $build_dir);
}

# For each --with-<package> option, attempt to merge in its changes
my @pkgs = ();
my @msn_pkgs = ();
while (my $option = shift(@ARGV)) {
	next unless ($option =~ m/with-([a-zA-Z0-9]+)/);

	# Skip killmsgs for Lingor as it is unnecessary
	next if ($args{'world'} eq 'lingor' && $1 eq 'killmsgs');

	my $pkg_dir = "$base_dir/pkg/$1";
	if (!-d $pkg_dir) {
		print "ERROR: Package dir $pkg_dir does not exist\n";
		next;
	}

	push(@pkgs, $pkg_dir);
	push(@msn_pkgs, "$msn_dir/$1") if (-d "$msn_dir/$1");
}

# Create the dayz_server PBO
if (scalar(@pkgs) > 0) {
	merge_packages(\@pkgs, $build_dir, $pkg_build_dir);
}

pack_world($build_dir, "$dst_dir/\@bliss_$args{'instance'}.$args{'world'}/addons");
copy("$base_dir/util/blisshive.dll", "$dst_dir/\@bliss_$args{'instance'}.$args{'world'}/blisshive.dll");

# Create the mission PBO
copy_dir("$msn_dir/world/$args{'world'}", $msn_build_dir);
if (scalar(@msn_pkgs) > 0) {
	merge_packages(\@msn_pkgs, $msn_build_dir, $msn_build_dir);
}

pack_mission($args{'instance'}, $args{'world'}, "$tmp_dir/mission_tmp", "$dst_dir/MPMissions");

remove_tree($tmp_dir);
print "INFO: Build completed successfully!\n";
exit;

# Merge helpers
sub simple_merge {
	my ($src, $dst) = @_;

	die "FATAL: Source path $src does not exist\n" unless (-d $src);
	die "FATAL: Destination path $dst does not exist\n" unless (-d $dst);

	File::DirCompare->compare($src, $dst, sub {
		my ($srcPath, $dstPath) = @_;

		if (!$dstPath) {
			return if (-d $srcPath);

			# New file, copy it from $srcPath
			my @dstSplit = File::Spec->splitdir($dst);
			my @srcSplit = File::Spec->splitdir(dirname($srcPath));
			my $dstLast = pop(@dstSplit);
			my $srcLast = pop(@srcSplit);
			$dstPath = "$dst/" . (($srcLast ne $dstLast) ? "$srcLast/" : '') . basename($srcPath);

			#print "SRC $srcPath -> $dstPath\n";
			make_path(dirname($dstPath)) unless (-d dirname($dstPath));
			copy($srcPath, $dstPath) unless (-d $dstPath);
		} elsif ($srcPath) {
			my $diff = Text::Diff::diff($dstPath, $srcPath, { STYLE => 'Unified' });
			my $srcData = read_file($dstPath);
			my $dstData = patch($srcData, $diff, { STYLE => 'Unified' });

			my @dstSplit = File::Spec->splitdir($dst);
			my @srcSplit = File::Spec->splitdir(dirname($srcPath));
			my $dstLast = pop(@dstSplit);
			my $srcLast = pop(@srcSplit);
			$dstPath = "$dst/" . (($srcLast ne $dstLast) ? "$srcLast/" : '') . basename($srcPath);

			#print "MRG $srcPath -> $dstPath\n";
			make_path(dirname($dstPath));
			write_file($dstPath, $dstData);
		}
	});
}

sub complex_merge {
	my ($orig, $src, $dst) = @_;

	die "FATAL: Origin path $orig does not exist\n" unless (-d $orig);
	die "FATAL: Source path $src does not exist\n" unless (-d $src);
	die "FATAL: Destination path $dst does not exist\n" unless (-d $dst);

	File::DirCompare->compare($orig, $dst, sub {
		my ($origPath, $dstPath) = @_;

		if ($origPath && $dstPath) {
			#print "MRG $origPath -> $dstPath\n";

			# Perform a three-way merge of the files 
			my @origSplit = File::Spec->splitdir(dirname($origPath));
			my $origLast = pop(@origSplit);
			my $srcPath = "$src/$origLast/" . basename($origPath);

			my $cmd = (($^O =~ m/MSWin32/) ? 'util\\diff3.exe --diff-program=util\\diff.exe -m' : 'diff3 -m');
			my $diffOutput = `$cmd $srcPath $origPath $dstPath`;

			$diffOutput =~ s/^[<=>\|]{7}.*//mg;
			$diffOutput =~ s/(\n){2,}/\n/sg;

			make_path(dirname($dstPath)) unless (-d dirname($dstPath));
			write_file($dstPath, $diffOutput);
		}
	});
}

# Perform merge of package changes into output dir
sub merge_packages {
	my ($ref_pkgs, $dst, $tmp) = @_;
	my @pkgs = @{$ref_pkgs};

	die "FATAL: Destination path $dst does not exist\n" unless (-d $dst);

	foreach my $i (0 .. $#pkgs) {
		my $src = $pkgs[$i];

		print "Merging changes for package $src\n";
		if ($i > 0) {
			my @pkg_slice = @pkgs[0 .. ($i - 1)];
			remove_tree($tmp);
			copy_dir($src, $tmp);
			foreach my $replay_pkg (@pkg_slice) {
				complex_merge($replay_pkg, $src, $tmp);
			}
			$src = $tmp;
		}
	
		File::DirCompare->compare($src, $dst, sub {
			my ($srcPath, $dstPath) = @_;

			if (!$dstPath) {
				# New file, copy it from $srcPath
				my @srcSplit = File::Spec->splitdir(dirname($srcPath));
				my $srcLast = pop(@srcSplit);
				$dstPath = "$dst/$srcLast/" . basename($srcPath);

				#print "SRC $srcPath -> $dstPath\n";
				make_path(dirname($dstPath)) unless (-d dirname($dstPath));
				copy($srcPath, $dstPath) unless (-d $dstPath);
			} elsif ($srcPath) {
				#print "MRG $srcPath -> $dstPath\n";

				my $diff = diff($dstPath, $srcPath, { STYLE => 'Unified' });
				my $srcData = read_file($dstPath);
				my $dstData = patch($srcData, $diff, { STYLE => 'Unified' });

				my @srcSplit = File::Spec->splitdir(dirname($srcPath));
				my $srcLast = pop(@srcSplit);
				$dstPath = "$dst/$srcLast/" . basename($srcPath);

				make_path(dirname($dstPath)) unless (-d dirname($dstPath));
				write_file($dstPath, $dstData);
			}
		});
	}
}

sub configure_deploy {
	my ($instance, $world, $src_bat, $src, $dst) = @_;
	my $conf_dir = "$dst/dayz_$instance.$world";

	# Check that required files exist
	return unless (-d $src && !-d $conf_dir && -f $src_bat);

	# Copy base config directory to the instance-specific path
	print "INFO: Creating configuration dayz_$instance.$world\n";
	copy_dir($src, $conf_dir);

	# Copy bat file if one does not already exist 
	my $dst_bat = "$dst/server_${world}_$instance.bat";
	if ($src_bat ne $dst_bat && !-f $dst_bat) {
		copy($src_bat, $dst_bat);
		$src_bat = $dst_bat;
	}

	# Ensure proper mission name is specified in config.cfg
	replace_text("s/template\\s=\\sdayz_[0-9]+.[a-z]+/template = dayz_$instance.$world/", "$conf_dir/config.cfg");

	my $mods = {
		'lingor'    => '\@dayzlingor',
		'takistan'  => '\@dayztakistan',
		'fallujah'  => '\@dayzfallujah',
		'zargabad'  => '\@dayzzargabad',
		'utes'      => '\@dayz',
		'panthera2' => '\@dayzpanthera',
		'namalsk'   => '\@dayz;\@dayz_namalsk;\@namalsk;\@nc'
	};

	# Ensure proper modfolders are specified in .bat file
	if (defined $mods->{$world}) {
		$mods->{$world} .= ";\\\@bliss_$instance.$world";
		replace_text("s/\\\"-mod=.*\\\"/\\\"-mod=$mods->{$world}\\\"/", $src_bat);
	}

	# Ensure proper profile directory is specified in .bat file
	replace_text("s/=dayz_1.chernarus/=dayz_$instance.$world/g", $src_bat);

	# Obfuscate the configuration/password if not already performed
	if (-f "$conf_dir/config.cfg") {
		my $start = int(rand(32));
		my $hash = substr(sha1_hex(time()), $start, 8);
		print "INFO: RCon password will be set to $hash\n";

		# Copy config.cfg to secured path, substitute values and update .bat file
		rename("$conf_dir/config.cfg", "$conf_dir/config_$hash.cfg");
		replace_text("s/passwordAdmin\\s=\\s\\\"\\\"/passwordAdmin = \\\"$hash\\\"/", "$conf_dir/config_$hash.cfg");
		replace_text("s/RConPassword\\s[0-9a-fA-F]{8}/RConPassword $hash/", "$conf_dir/BattlEye/BEServer.cfg");
		replace_text("s/config=dayz_$instance.$world\\\\config_[0-9a-fA-F]{8}.cfg/config=dayz_$instance.$world\\\\config_$hash.cfg/", $src_bat);
	}
}

# .pbo packing helpers
sub pack_pbo {
	my ($dir, $pbo) = @_;
	die "FATAL: PBO directory $dir does not exist\n" unless (-d $dir);

	my $cmd = (($^O =~ m/MSWin32/) ? '' : 'wine ') . 'util/cpbo.exe -y -p';
	system("$cmd \"$dir\" \"$pbo\"");
}

sub pack_world {
	my ($src, $dst) = @_;

	print "INFO: Creating dayz_server.pbo\n";
	make_path($dst) unless (-d $dst);
	pack_pbo($src, "$dst/dayz_server.pbo");
	remove_tree($src);
}

sub pack_mission {
	my ($instance, $world, $src, $dst) = @_;
	my $name = "dayz_$instance.$world";

	# Substitute the instance ID into init.sqf
	replace_text("s/dayZ_instance\\s=\\s[0-9]*/dayZ_instance = $instance/", "$src/init.sqf");

	print "INFO: Creating $name.pbo\n";
	make_path($dst) unless (-d $dst);
	pack_pbo($src, "$dst/$name.pbo");

	# Reset the instance ID in init.sqf
	replace_text("s/dayZ_instance\\s=\\s[0-9]*/dayZ_instance = 1/", "$src/init.sqf");
}


# Cross-platform system() helpers 
sub replace_text {
	system("perl -pi" . (($^O eq "MSWin32") ? '.bak' : '') . " -e \"$_[0]\" $_[1]");
	# Clean up .bak file in Windows only
	if ($^O eq "MSWin32") {
		(my $bakPath = $_[1]) =~ s/\//\\/g;
		system("del \"$bakPath.bak\"");
	}
}

sub copy_dir {
	my ($src, $dst) = @_;
	my $cmd = (($^O =~ m/MSWin32/) ? 'xcopy /s /q /y' : 'cp -r');
	my $path = "\"$src\" \"$dst\/\"";
	$path =~ s/\//\\/g if ($^O =~ m/MSWin32/);
	system("$cmd $path");
}
