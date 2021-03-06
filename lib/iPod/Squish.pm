#!/usr/bin/perl

package iPod::Squish;
use Moose;

our $VERSION = "0.02";

use MooseX::Types::Moose qw(Bool Int Undef HashRef);
use MooseX::Types::Path::Class qw(Dir);

with qw(
	MooseX::Getopt::Dashes
	MooseX::Runnable
	MooseX::LogDispatch
);

use Carp;
#use FFmpeg::Command;
#use Audio::File; # this dep fails if flac fails to build, so we use MP3::Info directly for now
use Number::Bytes::Human qw(format_bytes);
use MP3::Info qw(get_mp3info);
use MP3::Tag;
use File::Temp;
#use Parallel::ForkManager;
use File::Which;

has '+use_logger_singleton' => ( default => 1 );

has minimum_saving => (
	isa => Int,
	is  => "ro",
	default => 256 * 1024,
);

has use_lame => (
	isa => Bool,
	is  => "rw",
	default => sub { defined which("lame") },
);

has volume => (
	isa => Dir,
	is  => "ro",
	coerce   => 1,
);

has ipod_filename_mangling => (
	isa => Bool,
	is  => "ro",
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->music_dir =~ /iPod_Control/;
	},
);

has music_dir => (
	isa => Dir,
	is  => "ro",
	lazy => 1,
	default => sub {
		my $self = shift;

		my $ipod = $self->volume->subdir( qw(iPod_Control Music) );

		return $ipod if -d $ipod;

		my $generic = $self->volume->subdir("Music");

		return $generic if -d $generic;

		croak "Can't guess music directory, please specify --music-dir";
	},
	coerce => 1,
);

has target_bitrate => (
	isa => Int,
	is  => "ro",
	default => 128,
);

has jobs => (
	isa => Int|Undef,
	is  => "ro",
	default => 2,
);

has fork_manager => (
	is => "ro",
	init_arg   => undef,
	lazy_build => 1,
);

sub _build_fork_manager {
	my $self = shift;

	my $jobs = $self->jobs;

	return unless $jobs or $jobs <= 1;

	require Parallel::ForkManager;
	return Parallel::ForkManager->new( $jobs );
}

has ffmpeg_output_options => (
	isa => HashRef,
	is  => "ro",
	default    => sub { {} },
	auto_deref => 1,
);

sub get_bitrate {
	my ( $self, $file ) = @_;

	# for when we support more than just MP3s
	#( Audio::File->new($file->stringify) || return 0 )->audio_properties->bitrate;

	my $info = get_mp3info( "$file" ) or return 0;

	return $info->{BITRATE} || 0;
}

sub BUILD {
	# Early build
	shift->music_dir;
}

sub run {
	my $self = shift;

	my @files;

	$self->music_dir->recurse( callback => sub {
		my $file = shift;
		push @files, $file if -f $file;
	});

	$self->process_files(@files);
}

sub process_files {
	my ( $self, @files ) = @_;

	my @need_encoding;

	my %bitrate;
	foreach my $i ( 0 .. $#files ) {
		if ( my $bitrate = $self->needs_encoding( $files[$i], $i + 1, scalar(@files) ) ) {
			$bitrate{$files[$i]} = $bitrate;
			push @need_encoding, $files[$i];
		}
	}
	@need_encoding = sort { $bitrate{$b} <=> $bitrate{$a} or $a cmp $b } @need_encoding;

	foreach my $i ( 0 .. $#need_encoding ) {
		$self->reencode_file($need_encoding[$i], $i + 1, scalar(@need_encoding));
	}

	if ( my $pm = $self->fork_manager ) {
		$pm->wait_all_children;
	}

	return @need_encoding;
}

sub needs_encoding {
	my ( $self, $file, $n, $tot ) = @_;

	# itunes keep files in their original name during copying and get renamed
	# afterwords, this way we don't get a race condition
	return if $self->ipod_filename_mangling and $file->basename !~ /^[A-Z]{4}(?: \d+)?\.mp3$/;

	my $bitrate = $self->get_bitrate($file);

	if (
		# make sure there is enough of a bitrate different
		$bitrate > ( 1.05 * $self->target_bitrate )
			and
		# and make sure the estimated savings in bytes is sensible
		( ( ( $bitrate - $self->target_bitrate ) / $bitrate ) * -s $file ) >= $self->minimum_saving
	) {
		$self->logger->log( level => "info", message => "queueing $file ($n/$tot), bitrate is $bitrate, estimated saving " . format_bytes( ( ( $bitrate - $self->target_bitrate ) / $bitrate ) * -s $file ) );
		return $bitrate;
	} else {
		$self->logger->log( level => "info", message => "skipping $file ($n/$tot), " . ( $bitrate ? "bitrate is $bitrate" : "error reading bitrate" ) );
		return;
	}
}

sub reencode_file {
	my ( $self, @args ) = @_;

	my $pm = $self->fork_manager;
	$pm->start and return if $pm;

	$self->_reencode_file(@args);

	$pm->finish if $pm;
}

sub _reencode_file {
	my ( $self, $file, $n, $tot ) = @_;

	my $size = -s $file;

	$self->logger->log( level => "info", message => "encoding $file ($n/$tot)" );

	# make the tempfile at the TLD of the iPod so we can rename() later
	my $tmp = File::Temp->new( UNLINK => 1, SUFFIX => ".mp3", DIR => $self->volume );

	if ( $self->run_encoder( $file->stringify, $tmp->filename ) ) {
		my $new_size = -s $tmp->filename;
		my $saved = $size - $new_size;

		$self->logger->log( level => "notice", message => sprintf "renaming %s, saved %s (%.2f%%) ($n/$tot)", $file, format_bytes($saved), ( $saved / $size ) * 100 );

		rename( $tmp->filename, $file )
			or $self->logger->log( level => "error", message => "Can't rename $tmp to $file" );

	} elsif ( ( $? & 127 ) != 2 ) { # SIGINT
		$self->logger->log( level => "error", message => "error in conversion of $file: $?" );
	}
}

sub copy_tags {
	my ( $self, $from, $to ) = @_;

	my $from_tag = MP3::Tag->new($from);
	$from_tag->get_tags;

	my $to_tag = MP3::Tag->new($to);

	if ( $from_tag->copy_id3v2_frames($to_tag, 'delete') ) {
		$to_tag->{ID3v2}->write_tag;
	} else {
		if ( exists $from_tag->{ID3v1} ) {
			my $to_id3v1 = $to_tag->new_tag("ID3v1");

			$to_id3v1->all( $from_tag->{ID3v1}->all );
			$to_id3v1->write_tag;
		}
	}
}

sub run_encoder {
	my ( $self, $in, $out, @args ) = @_;

	if ( $self->use_lame ) {
		$self->run_lame($in, $out, @args);
	} else {
		$self->run_ffmpeg($in, $out, @args);
	}

	$self->copy_tags($in, $out);
}

sub run_lame {
	my ( $self, $input, $output ) = @_;

	system ( qw(lame --silent -h --preset), $self->target_bitrate, $input, $output ) == 0;
}

sub run_ffmpeg {
	my ( $self, $input, $output ) = @_;

	require FFmpeg::Command;
	my $cmd = FFmpeg::Command->new;

	$cmd->input_options({ file => $input });

	$cmd->output_options({
		format         => "mp3",
		audio_codec    => "mp3",
		audio_bit_rate => $self->target_bitrate,
		$self->ffmpeg_output_options,
		file           => $output
	});

	$cmd->exec;
}

__PACKAGE__

__END__

=pod

=encoding utf8

=head1 NAME

iPod::Squish - Convert songs on an iPod in place using lame or
L<FFmpeg::Command>.

=head1 SYNOPSIS

	use iPod::Squish;

	my $squisher = iPod::Squish->new(
		volume => "/Volumes/iPod Name"
		target_bitrate => 128,
	);

	$squisher->run;

=head1 DESCRIPTION

This module uses F<lame> or L<FFmpeg::Command> to perform automatic conversion
of songs on an iPod after they've been synced.

Since most headphones are too crappy to notice converting songs to a lower
bitrate is often convenient to save size.

Only files with a bitrate over C<target_bitrate> will be converted.

Currently only MP3 files will be converted and the output format is MP3 as
well. AAC support would be nice, see L</TODO>.

A tip to sync more data than iTunes is willing is to do it in several steps by
using a smart playlist and limiting the number of songs in the playlist by the
number of free megabytes on the player. Then you can run the squishing script,
and repeat ad nauseum.

=head1 ATTRIBUTES

=over 4

=item volume

The mount point of the iPod you want to reencode.

=item target_bitrate

The bitrate to encode to.

Only songs whose bitrate is higher than this will be encoded.

=item use_lame

Use the C<lame> command directly instead of L<FFmpeg::Command>.

Defualts to true if C<lame> is in the path, because it's more flexible than
lame through ffmpeg.

Note that using lame is generally slower for the same C<target_bitrate> because
of the C<-h> flag passed to lame.

=item jobs

The number of parallel lame instances to run. Defaults to 2. Useful for multi
processor or multi core machines.

=back

=head1 METHODS

=over

=item run

Do the conversion by recursing through the iPod's music directory and running
C<process_file> for each file (possibly in parallel, see C<jobs>).

=item process_file $file

Attempt to convert the file, and if conversion succeeds replace the original
with the new version.

The file will only be converted if its an MP3.

=item reencode_file $file

Does the actual encoding/move of the file.

=back

=head1 LOGGING

This module uses L<MooseX::LogDispatch>, which in turn uses
L<Log::Dispatch::Config>. This allows you to control logging to your heart's
content. The default is to just print the messages to C<STDERR>.

=head1 TODO

=over 4

=item VBR

I'm not quite sure how to specify varible bitrate for C<ffmpeg>. Should look
into that.

=item m4a

Support C<m4a> type AAC files (I don't think ffmpeg allows this, but I'm not
quite sure). Encoding to AAC definitely is supported.

=item format consolidation

Check if an iPod will swallow files in a format different than the name/library
entry implies.

If not, try to use rewrite library entries, as long as this doesn't affect
synchronization.

Perhaps look at L<Mac::iPod::DB> for details.

=head1 OSX agent integration

Using an app called Lingon (L<http://lingon.sourceforge.net/>) you can easily
create an agent that will run every time a disk is mounted.

My entry is:

	nice /usr/local/bin/perl -I /Users/nothingmuch/Perl/iPod-Squish/lib /Users/nothingmuch/Perl/iPod-Squish/script/isquish

Because the script loops until no more songs are converted, and copying is
likely faster than encoding it should generally Just Work™ automatically.

Make sure you have F<lame> or F<ffmpeg> in the path, and if you want lame to
STFU then set TERM to something as well.

This can be done by using

	env TERM=xterm-color PATH=...

to actually run the script.

=head1 SEE ALSO

L<FFmpeg::Command>, L<Audio::File>, L<Mac::iPod::DB>,

=head1 VERSION CONTROL

This module is maintained using Darcs. You can get the latest version from
L<http://nothingmuch.woobling.org/code>, and use C<darcs send> to commit
changes.

=head1 AUTHOR

Yuval Kogman E<lt>nothingmuch@woobling.orgE<gt>

=head1 COPYRIGHT

	Copyright (c) 2008 Yuval Kogman. All rights reserved
	This program is free software; you can redistribute
	it and/or modify it under the same terms as Perl itself.

=cut
