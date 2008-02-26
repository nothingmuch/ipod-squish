#!/usr/bin/perl

package iPod::Squish;
use Moose;

our $VERSION = "0.01";

use MooseX::Types::Path::Class;

with qw(MooseX::LogDispatch);

use FFmpeg::Command;
#use Audio::File; # this dep fails if flac fails to build, so we use MP3::Info directly for now
use MP3::Info;
use File::Temp qw(:seekable);
use Parallel::ForkManager;

has volume => (
	isa => "Path::Class::Dir",
	is  => "ro",
	required => 1,
	coerce   => 1,
);

has mp3_dir => (
	isa => "Path::Class::Dir",
	is  => "ro",
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->volume->subdir( qw(iPod_Control Music) );
	},
);

has target_bitrate => (
	isa => "Int",
	is  => "ro",
	default => 128,
);

has jobs => (
	isa => "Int|Undef",
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

	return Parallel::ForkManager->new( $jobs );
}

has ffmpeg_output_options => (
	isa => "HashRef",
	is  => "ro",
	default    => sub { {} },
	auto_deref => 1,
);

sub get_bitrate {
	my ( $self, $file ) = @_;

	# for when we support more than just MP3s
	#( Audio::File->new($file->stringify) || return 0 )->audio_properties->bitrate;

	my $info = get_mp3info( $file->stringify ) or return 0;

	return $info->{BITRATE} || 0;
}

sub run {
	my $self = shift;

	my $pm = $self->fork_manager;

	$self->mp3_dir->recurse( callback => sub {
		my $file = shift;
		$self->process_file( $file ) if -f $file;
	});

	$pm->wait_all_children if $pm;
}

sub process_file {
	my ( $self, $file ) = @_;

	my $pm = $self->fork_manager;

	if ( $self->get_bitrate($file) > $self->target_bitrate ) {

		$self->logger->info("encoding $file");

		$pm->start and return if $pm;

		$self->reencode_file($file);

		$pm->finish if $pm;

	} else {
		$self->logger->info("skipping $file");
	}
}

sub reencode_file {
	my ( $self, $file ) = @_;

	# itunes keep files in their original name while copying, this way we don't
	# get a race condition
	return unless $file->basename =~ /^[A-Z]{4}(?: \d+)?\.mp3$/;

	my $cmd = FFmpeg::Command->new;

	$cmd->input_options({ file => $file->stringify });

	# make the tempfile at the TLD of the iPod so we can rename() later
	my $tmp = File::Temp->new( UNLINK => 1, SUFFIX => ".mp3", DIR => $self->volume );

	$cmd->output_options({
		format         => "mp3",
		audio_codec    => "mp3",
		audio_bit_rate => $self->target_bitrate,
		$self->ffmpeg_output_options,
		file           => $tmp->filename,
	});

	if ( $cmd->exec ) {
		$self->logger->info("replacing $file");
		rename( $tmp->filename, $file )
			or $self->logger->log_and_die( level => "error", message => "Can't rename $tmp to $file" );
	}
}
__PACKAGE__

__END__

=pod

=head1 NAME

iPod::Squish - Convert songs on an iPod in place using L<FFmpeg::Command>.

=head1 SYNOPSIS

	use iPod::Squish;

	my $squisher = iPod::Squish->new(
		volume => "/Volumes/iPod Name"
		target_bitrate => 128,
	);

	$squisher->run;

=head1 DESCRIPTION

This module uses L<FFmpeg::Command> to perform automatic conversion of songs on
an iPod after they've been synced.

Since most headphones are too crappy to notice converting songs to a lower
bitrate is often convenient to save size.

Only files with a bitrate over C<target_bitrate> will be converted.

Currently only MP3 files will be converted and the output format is MP3 as
well. AAC support would be nice, see L</TODO>.

=head1 ATTRIBUTES

=over 4

=item volume

The mount point of the iPod you want to reencode.

=item target_bitrate

The bitrate to encode to.

Only songs whose bitrate is higher than this will be encoded.

=item jobs

The number of parallel ffmpeg instances to run. Defaults to 2. Useful for multi
processor or multi core machines.

=item ffmpeg_output_options

Additional output options for C<FFmpeg::Command>.

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

=item launchd integration

Perhaps make a script to add a launchd service for a given ipod based on the
dir watching service, so that an iPod is squished automatically. This combined
with an on-mount watcher and an index of already converted files should allow
a fairly seamless workflow, even if you don't want to wait after syncing.

=item m4a

Support C<m4a> type AAC files (I don't think ffmpeg allows this, but I'm not
quite sure). Encoding to AAC definitely is supported.

=item format consolidation

Check if an iPod will swallow files in a format different than the name/library
entry implies.

If not, try to use rewrite library entries, as long as this doesn't affect
synchronization.

Perhaps look at L<Mac::iPod::DB> for details.

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
