package Mojolicious::Static;
use Mojo::Base -base;

use File::Spec::Functions 'catfile';
use Mojo::Asset::File;
use Mojo::Asset::Memory;
use Mojo::Date;
use Mojo::Home;
use Mojo::Loader;
use Mojo::Util 'md5_sum';

has classes => sub { ['main'] };
has paths   => sub { [] };

# Last modified default
my $MTIME = time;

# Bundled files
my $HOME   = Mojo::Home->new;
my $PUBLIC = $HOME->parse($HOME->mojo_lib_dir)->rel_dir('Mojolicious/public');

sub dispatch {
  my ($self, $c) = @_;

  # Canonical path
  my $stash = $c->stash;
  my $path  = $c->req->url->path;
  $path = $stash->{path} ? $path->new($stash->{path}) : $path->clone;
  return undef unless my @parts = @{$path->canonicalize->parts};

  # Serve static file and prevent directory traversal
  return undef if $parts[0] eq '..' || !$self->serve($c, join('/', @parts));
  $stash->{'mojo.static'}++;
  return !!$c->rendered;
}

sub file {
  my ($self, $rel) = @_;

  # Search all paths
  for my $path (@{$self->paths}) {
    next unless my $asset = $self->_get_file(catfile $path, split('/', $rel));
    return $asset;
  }

  # Search DATA
  if (my $asset = $self->_get_data_file($rel)) { return $asset }

  # Search bundled files
  return $self->_get_file(catfile($PUBLIC, split('/', $rel)));
}

sub is_fresh {
  my ($self, $c, $options) = @_;

  my $res_headers = $c->res->headers;
  my ($last, $etag) = @$options{qw(last_modified etag)};
  $res_headers->last_modified(Mojo::Date->new($last)) if $last;
  $res_headers->etag($etag = qq{"$etag"}) if $etag;

  # Unconditional
  my $req_headers = $c->req->headers;
  my $match       = $req_headers->if_none_match;
  return undef unless (my $since = $req_headers->if_modified_since) || $match;

  # If-None-Match
  return undef if $match && ($etag // $res_headers->etag // '') ne $match;

  # If-Modified-Since
  return !!$match unless ($last //= $res_headers->last_modified) && $since;
  return _epoch($last) <= (_epoch($since) // 0);
}

sub serve {
  my ($self, $c, $rel) = @_;
  return undef unless my $asset = $self->file($rel);
  my $types = $c->app->types;
  my $type = $rel =~ /\.(\w+)$/ ? $types->type($1) : undef;
  $c->res->headers->content_type($type || $types->type('txt'));
  return !!$self->serve_asset($c, $asset);
}

sub serve_asset {
  my ($self, $c, $asset) = @_;

  # Last-Modified and ETag
  my $res = $c->res;
  $res->code(200)->headers->accept_ranges('bytes');
  my $mtime = $asset->is_file ? (stat $asset->path)[9] : $MTIME;
  my $options = {etag => md5_sum($mtime), last_modified => $mtime};
  return $res->code(304) if $self->is_fresh($c, $options);

  # Range
  my $size = $asset->size;
  my ($start, $end) = (0, $size - 1);
  if (my $range = $c->req->headers->range) {

    # Not satisfiable
    return $res->code(416) unless $size && $range =~ m/^bytes=(\d+)?-(\d+)?/;
    $start = $1 if defined $1;
    $end = $2 if defined $2 && $2 <= $end;
    return $res->code(416) if $start > $end || $end > ($size - 1);

    # Satisfiable
    $res->code(206)->headers->content_length($end - $start + 1)
      ->content_range("bytes $start-$end/$size");
  }

  return $res->content->asset($asset->start_range($start)->end_range($end));
}

sub _epoch { Mojo::Date->new(shift)->epoch }

sub _get_data_file {
  my ($self, $rel) = @_;

  # Protect templates
  return undef if $rel =~ /\.\w+\.\w+$/;

  # Index DATA files
  my $loader = Mojo::Loader->new;
  unless ($self->{index}) {
    my $index = $self->{index} = {};
    for my $class (reverse @{$self->classes}) {
      $index->{$_} = $class for keys %{$loader->data($class)};
    }
  }

  # Find file
  return undef
    unless defined(my $data = $loader->data($self->{index}{$rel}, $rel));
  return Mojo::Asset::Memory->new->add_chunk($data);
}

sub _get_file {
  my ($self, $path) = @_;
  no warnings 'newline';
  return -f $path && -r $path ? Mojo::Asset::File->new(path => $path) : undef;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Static - Serve static files

=head1 SYNOPSIS

  use Mojolicious::Static;

  my $static = Mojolicious::Static->new;
  push @{$static->classes}, 'MyApp::Controller::Foo';
  push @{$static->paths}, '/home/sri/public';

=head1 DESCRIPTION

L<Mojolicious::Static> is a static file server with C<Range> and
C<If-Modified-Since> support based on
L<RFC 7232|http://tools.ietf.org/html/rfc7232> and
L<RFC 7233|http://tools.ietf.org/html/rfc7233>.

=head1 ATTRIBUTES

L<Mojolicious::Static> implements the following attributes.

=head2 classes

  my $classes = $static->classes;
  $static     = $static->classes(['main']);

Classes to use for finding files in C<DATA> sections, first one has the
highest precedence, defaults to C<main>.

  # Add another class with static files in DATA section
  push @{$static->classes}, 'Mojolicious::Plugin::Fun';

=head2 paths

  my $paths = $static->paths;
  $static   = $static->paths(['/home/sri/public']);

Directories to serve static files from, first one has the highest precedence.

  # Add another "public" directory
  push @{$static->paths}, '/home/sri/public';

=head1 METHODS

L<Mojolicious::Static> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 dispatch

  my $bool = $static->dispatch(Mojolicious::Controller->new);

Serve static file for L<Mojolicious::Controller> object.

=head2 file

  my $asset = $static->file('images/logo.png');
  my $asset = $static->file('../lib/MyApp.pm');

Build L<Mojo::Asset::File> or L<Mojo::Asset::Memory> object for a file,
relative to L</"paths"> or from L</"classes">. Note that this method does not
protect from traversing to parent directories.

  my $content = $static->file('foo/bar.html')->slurp;

=head2 is_fresh

  my $bool = $static->is_fresh(Mojolicious::Controller->new, {etag => 'abc'});

Check freshness of request by comparing the C<If-None-Match> and
C<If-Modified-Since> request headers to the C<ETag> and C<Last-Modified>
response headers.

These options are currently available:

=over 2

=item etag

  etag => 'abc'

Add C<ETag> header before comparing.

=item last_modified

  last_modified => $epoch

Add C<Last-Modified> header before comparing.

=back

=head2 serve

  my $bool = $static->serve(Mojolicious::Controller->new, 'images/logo.png');
  my $bool = $static->serve(Mojolicious::Controller->new, '../lib/MyApp.pm');

Serve a specific file, relative to L</"paths"> or from L</"classes">. Note
that this method does not protect from traversing to parent directories.

=head2 serve_asset

  $static->serve_asset(Mojolicious::Controller->new, Mojo::Asset::File->new);

Serve a L<Mojo::Asset::File> or L<Mojo::Asset::Memory> object with C<Range>
and C<If-Modified-Since> support.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
