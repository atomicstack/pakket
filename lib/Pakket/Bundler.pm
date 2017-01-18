package Pakket::Bundler;
# ABSTRACT: Bundle pakket packages into a parcel file

use Moose;
use MooseX::StrictConstructor;
use JSON::MaybeXS;
use File::Spec;
use Path::Tiny        qw< path >;
use Types::Path::Tiny qw< Path >;
use Log::Any          qw< $log >;

use Pakket::Constants qw<
    PARCEL_EXTENSION
    PARCEL_FILES_DIR
    PARCEL_METADATA_FILE
>;

use constant {
    'BUNDLE_DIR_TEMPLATE' => 'BUNDLE-XXXXXX',
};

has 'bundle_dir' => (
    'is'      => 'ro',
    'isa'     => Path,
    'coerce'  => 1,
    'default' => sub { return path('output') },
);

has 'files_manifest' => (
    'is'      => 'ro',
    'isa'     => 'HashRef',
    'default' => sub { return +{} },
);

sub bundle {
    my ( $self, $build_dir, $pkg_data, $files ) = @_;

    my (
        $package_category, $package_name,
        $package_version,  $package_config,
    ) = @{$pkg_data}{qw< category name version config >};

    my $original_dir = Path::Tiny->cwd;

    # totally arbitrary, maybe add to constants?
    my $parcel_dir_path = Path::Tiny->tempdir(
        'TEMPLATE' => BUNDLE_DIR_TEMPLATE(),
        'CLEANUP'  => 1,
    );

    $parcel_dir_path->child( PARCEL_FILES_DIR() )->mkpath;

    chdir $parcel_dir_path->child( PARCEL_FILES_DIR() )->stringify;

    foreach my $orig_file ( keys %{$files} ) {
        $log->debug("Bundling $orig_file");
        my $new_fullname = $self->_rebase_build_to_output_dir(
            $build_dir, $orig_file,
        );

        -e $new_fullname
            and die 'Odd. File already seems to exist in packaging dir. '
                  . "Stopping.\n";

        # create directories
        $new_fullname->parent->mkpath;

        # regular file
        if ( $files->{$orig_file} eq '' ) {
            path($orig_file)->copy($new_fullname)
                or die "Failed to copy $orig_file to $new_fullname\n";

            my $raw_mode = ( stat($orig_file) )[2];
            my $mode_str = sprintf '%04o', $raw_mode & oct('07777');
            chmod oct($mode_str), $new_fullname;
        } else {
            my $new_symlink = $self->_rebase_build_to_output_dir(
                $build_dir, $files->{$orig_file},
            );

            my $previous_dir = Path::Tiny->cwd;
            chdir $new_fullname->parent;
            symlink $new_symlink, $new_fullname->basename;
            chdir $previous_dir;
        }
    }

    path( PARCEL_METADATA_FILE() )
        ->spew_utf8( JSON::MaybeXS->new->pretty->canonical->encode($package_config) );

    chdir '..';

    my $parcel_filename = path(
        join '.', "$package_name-$package_version", PARCEL_EXTENSION,
    );

    $log->info("Creating parcel file $parcel_filename");
    system "tar -cJf $parcel_filename *";
    my $new_location = path(
        $self->bundle_dir, $package_category, $package_name,
    );

    $new_location->mkpath;

    # "A lot of Unix systems simply don't allow the mv command to work between
    # different devices # (or even different partitions on the same device).
    # The solution is to copy the file over, and then delete the original -
    # or use GNU mv, which will do the same thing automaticaly."
    #   -- http://www.perlmonks.org/?node_id=338699
    #
    # this happened because it was installed in /tmp which was a different FS
    #   -- SX (see: d81d413e6df49c1c7284e4474457e1cd9b6655b4)
    $parcel_filename->copy($new_location);
    $parcel_filename->remove();

    chdir $original_dir;

    return;
}

sub _rebase_build_to_output_dir {
    my ( $self, $build_dir, $orig_filename ) = @_;
    ( my $new_filename = $orig_filename ) =~ s/^$build_dir//ms;
    my @parts = File::Spec->splitdir($new_filename);

    # in case the path is absolute (leading slash)
    # the split function will generate an empty first element
    # if it's relative, it will have value and shouldn't be removed
    $parts[0] eq '' and shift @parts;

    return path(@parts);
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__
