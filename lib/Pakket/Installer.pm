package Pakket::Installer;
# ABSTRACT: Install pakket packages into an installation directory

use Moose;
use MooseX::StrictConstructor;
use Path::Tiny            qw< path  >;
use Types::Path::Tiny     qw< Path  >;
use File::Copy::Recursive qw< dircopy >;
use Time::HiRes           qw< time >;
use Log::Any              qw< $log >;
use JSON::MaybeXS         qw< decode_json >;
use Archive::Any;

use Pakket::Repository::Parcel;
use Pakket::Package;
use Pakket::Utils         qw< is_writeable >;
use Pakket::Constants qw<
    PARCEL_METADATA_FILE
    PARCEL_FILES_DIR
    PAKKET_PACKAGE_SPEC
>;

with 'Pakket::Role::RunCommand';

# Sample structure:
# ~/.pakket/
#        bin/
#        etc/
#        repos/
#        libraries/
#                  active ->
#

has 'pakket_libraries_dir' => (
    'is'      => 'ro',
    'isa'     => Path,
    'coerce'  => 1,
    'builder' => '_build_pakket_libraries_dir',
);

has 'pakket_dir' => (
    'is'       => 'ro',
    'isa'      => Path,
    'coerce'   => 1,
    'required' => 1,
);

has 'parcel_dir' => (
    'is'       => 'ro',
    'isa'      => Path,
    'coerce'   => 1,
    'required' => 1,
);

has 'keep_copies' => (
    'is'      => 'ro',
    'isa'     => 'Int',
    'default' => sub {1},
);

has 'input_file' => (
    'is'        => 'ro',
    'isa'       => Path,
    'coerce'    => 1,
    'predicate' => '_has_input_file',
);

has 'parcel_repo' => (
    'is'      => 'ro',
    'isa'     => 'Pakket::Repository::Parcel',
    'lazy'    => 1,
    'builder' => '_build_parcel_repo',
);

# We're starting with a local repo
# # but in the future this will be dictated from a configuration
sub _build_parcel_repo {
    my $self   = shift;

    # Use default for now, but use the directory we want at least
    return Pakket::Repository::Parcel->new(
        'directory' => $self->parcel_dir,
    );
}

sub _build_pakket_libraries_dir {
    my $self = shift;
    return $self->pakket_dir->child('libraries');
}

# TODO:
# this should be implemented using a fetcher class
# because it might be from HTTP/FTP/Git/Custom/etc.
sub fetch_package;

sub install {
    my ( $self, @packages ) = @_;

    if ( $self->_has_input_file ) {
        my $content = decode_json $self->input_file->slurp_utf8;
        foreach my $category ( keys %{$content} ) {
            push @packages, Pakket::Package->new(
                'name'     => $_,
                'category' => $category,
                'version'  => $content->{$category}{$_}{'latest'},
            ) for keys %{ $content->{$category} };
        }
    } else {
        my @clean_packages;
        foreach my $package_str (@packages) {
            my ( $pkg_cat, $pkg_name, $pkg_version ) =
                $package_str =~ PAKKET_PACKAGE_SPEC();

            if ( !defined $pkg_version ) {
                $log->critical(
                    'Currently you must provide a version to install',
                );

                exit 1;
            }

            push @clean_packages, Pakket::Package->new(
                'category' => $pkg_cat,
                'name'     => $pkg_name,
                'version'  => $pkg_version,
            );
        }

        @packages = @clean_packages;
    }

    if ( !@packages ) {
        $log->notice('Did not receive any parcels to deliver');
        return;
    }

    my $pakket_libraries_dir = $self->pakket_libraries_dir;

    $pakket_libraries_dir->is_dir
        or $pakket_libraries_dir->mkpath();

    my $work_dir = $pakket_libraries_dir->child( time() );

    if ( $work_dir->exists ) {
        $log->critical(
            "Internal installation directory exists ($work_dir), exiting",
        );

        exit 1;
    }

    $work_dir->mkpath();

    my $active_link = $pakket_libraries_dir->child('active');

    # we copy any previous installation
    if ( $active_link->exists ) {
        my $orig_work_dir = eval { my $link = readlink $active_link } or do {
            $log->critical("$active_link is not a symlink");
            exit 1;
        };

        dircopy( $pakket_libraries_dir->child($orig_work_dir), $work_dir );
    }

    my $installer_cache = {};
    foreach my $package (@packages) {
        $self->install_package( $package, $work_dir, { 'cache' => $installer_cache } );
    }

    # We finished installing each one recursively to the work directory
    # Now we need to set the symlink

    if ( $active_link->exists ) {
        # delete the active symlink
        $log->debug('Deleting existing active symlink');
        $active_link->remove;
    }
    $log->debug('Setting active symlink to new work directory');
    if ( ! symlink $work_dir->basename, $active_link ) {
        $log->error('Could not activate new installation (symlink create failed)');
        exit 1;
    }

    $log->infof(
        "Finished installing %d packages into $pakket_libraries_dir",
        scalar keys %{$installer_cache},
    );

    # Clean up
    my $keep = $self->keep_copies;

    if ( $keep <= 0 ) {
        $log->warning(
            "You have set your 'keep_copies' to 0 or less. " .
            "Resetting it to '1'.",
        );

        $keep = 1;
    }

    my @dirs = sort { $a->stat->mtime <=> $b->stat->mtime }
               grep +( $_->basename ne 'active' && $_->is_dir ),
               $pakket_libraries_dir->children;

    my $num_dirs = @dirs;
    foreach my $dir (@dirs) {
        $num_dirs-- <= $keep and last;
        $log->debug("Removing old directory: $dir");
        path($dir)->remove_tree( { 'safe' => 0 } );
    }

    return;
}

sub try_to_install_package {
    my ( $self, $package, $dir, $opts ) = @_;

    $log->debugf( 'Trying to install %s', $package->full_name );

    eval {
        $self->install_package( $package, $dir, $opts );
        1;
    } or do {
        $log->debugf( 'Could not install %s', $package->full_name );
        return;
    };

    return 1;
}

sub install_package {
    my ( $self, $package, $dir, $opts ) = @_;
    my $installer_cache = $opts->{'cache'};

    # Are we in a regular (non-bootstrap) mode?
    # Are we using a bootstrap version of a package?
    if ( ! $opts->{'skip_prereqs'} && $package->is_bootstrap ) {
        $log->critical(
            'You are trying to install a bootstrap version of %s.'
          . ' Please rebuild this package from scratch.',
            $package->full_name,
        );

        exit 1;
    }

    my $pkg_cat        = $package->category;
    my $pkg_name       = $package->name;
    my $pkg_version    = $package->version;
    my $pkg_short_name = $package->short_name;

    $log->debugf( "About to install %s (into $dir)", $package->full_name );

    if ( defined $installer_cache->{$pkg_cat}{$pkg_name} ) {
        my $version = $installer_cache->{$pkg_cat}{$pkg_name};

        if ( $version ne $pkg_version ) {
            $log->critical(
                "$pkg_short_name=$version already installed. "
              . "Cannot install new version: $pkg_version",
            );

            exit 1;
        }

        $log->debugf( '%s already installed.', $package->full_name );

        return;
    } else {
        $installer_cache->{$pkg_cat}{$pkg_name} = $pkg_version;
    }

    if ( !is_writeable($dir) ) {
        $log->critical(
            "Can't write to your installation directory ($dir)",
        );

        exit 1;
    }

    my $parcel_file
        = $self->parcel_repo->retrieve_location( $package->full_name );

    $parcel_file->copy($dir);

    my $parcel_basename = $parcel_file->basename;

    $log->debug("Unpacking $parcel_basename into $dir");

    # Unpack into a separate directory
    my $tmp_extraction_dir = Path::Tiny->tempdir(
        'CLEANUP' => 1,
        'DIR'     => $dir->stringify,
    );

    my $archive = Archive::Any->new($parcel_file);
    $archive->extract($tmp_extraction_dir);

    my $full_parcel_dir = $tmp_extraction_dir->child( PARCEL_FILES_DIR() );

    my $spec_file = $full_parcel_dir->child( PARCEL_METADATA_FILE() );
    my $config    = decode_json $spec_file->slurp_utf8;

    $dir->child($parcel_basename)->remove;

    my $prereqs = $config->{'Prereqs'};
    foreach my $prereq_category ( keys %{$prereqs} ) {
        my $runtime_prereqs = $prereqs->{$prereq_category}{'runtime'};

        foreach my $prereq_name ( keys %{$runtime_prereqs} ) {
            my $prereq_data    = $runtime_prereqs->{$prereq_name};
            my $prereq_version = $prereq_data->{'version'};

            # FIXME We shouldn't be constructing this,
            #       We should just ask the repo for it
            #       It should maintain metadata for this
            #       and API to retrieve it
            # FIXME This shouldn't be a package but a prereq object
            my $next_pkg = Pakket::Package->new(
                'category' => $prereq_category,
                'name'     => $prereq_name,
                'version'  => $prereq_version,
            );

            $self->install_package( $next_pkg, $dir, $opts );
        }
    }

    foreach my $item ( $full_parcel_dir->children ) {
        my $basename = $item->basename;

        $basename eq PARCEL_METADATA_FILE()
            and next;

        my $target_dir = $dir->child($basename);
        dircopy( $item, $target_dir );
    }

    my $actual_version = $config->{'Package'}{'version'};
    $log->info("Delivered parcel $pkg_cat/$pkg_name ($actual_version)");

    return;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__
