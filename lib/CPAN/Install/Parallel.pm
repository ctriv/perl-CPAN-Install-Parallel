package CPAN::Install::Parallel;

use strict;
use warnings;

use Module::CPANfile;
use MetaCPAN::Client;
use CHI;
use WWW::Mechanize::Cached;
use HTTP::Tiny::Mech;
use Module::CoreList;
use Data::Dumper;
use Parallel::Runner;
use Moose;
use namespace::autoclean;

has cpanfile  => (is => 'ro', isa => 'Str', required => 1, default => 'cpanfile');
has workers   => (is => 'ro', isa => 'Int', required => 1, default => 4);
has runner    => (
	is      => 'ro',
	isa     => 'Parallel::Runner',
	lazy    => 1,
	builder => '_build_runner'
);
has cache     => (is => 'ro', isa => 'Bool', required => 1, default => 0);
has cache_dir => (is => 'ro', isa => 'Str',  default => '/tmp/cpan-install-parallel');
has metacpan  => (
	is      => 'ro',
	isa     => 'MetaCPAN::Client',
	lazy    => 1,
	builder => '_build_metacpan_client',
);

__PACKAGE__->meta->make_immutable;

=head1 NAME

CPAN::Install::Parallel - Install cpan modules faster

=head1 SYNOPSIS

	CPAN::Install::Parallel->run(
		workers  => 16,
		cache    => 1,
		cpanfile => 'dir/cpanfile'
	);


=head1 DESCRIPTION

There are a number of good tools for installing cpan modules via a cpanfile or
a cpan META file, however if you have a very large application installing those
modules can take a very long time.  This module attacks that problem.

First the given cpanfile is parsed to get a list of required modules.  Then a
dependency tree is built using the metacpan api to determain the dependency
relationships.  After the tree is built, a post-order traversal gives us an order
to install where depencies are installed first.  Throw in L<Parallel::Runner>
while we're walking the tree, and we have a relatively sane way to install
modules in parallel.

This approach isn't perfect, you can still run into timing issues where worker A
has started on a module that worker B depends on.  With the current work B will
try to install what A is working on.  

=head1 METHODS

=head2 run

Do the install.  Takes the following options:

=over 2

=item cpanfile

The L<cpanfile> that should be loaded.  Defaults to C<cpanfile>.

=item workers

The number of worker processes to run in parallel.  Defaults to 4.

=item cache

Boolean.  If true the calls to the metacpan api will be cached.  Recommended,
but defaults to false.

=item cache_dir

Cache directory for the above caching option.  Defaults to
C</tmp/cpan-install-parallel>

=back

=cut

sub run {
	my $self = shift->new(@_);
	
	my $modules = $self->parse_cpanfile();
	my $tree    = $self->build_dependency_tree($modules);
	
	$self->walk_tree($tree);
}


sub parse_cpanfile {
	my ($self) = @_;
	
	my $cpanfile = Module::CPANfile->load($self->cpanfile);
	my $prereqs  = $cpanfile->prereqs->merged_requirements;
	
	return $prereqs->as_string_hash;	
}


my %skip = map { $_ => 1 } qw/perl strict warnings parent base overload lib utf8 constant B blib threads/;

sub build_dependency_tree {
	my ($self, $modules, $seen, $tree) = @_;
	
	my $mcpan = $self->metacpan;
	
	$tree ||= {};
	$seen ||= {};
	
	while (my ($name, $version) = each %$modules) {
		if ($seen->{$name}) {
			$tree->{$name} = $seen->{$name};
			next;
		}
		next if $skip{$name} or Module::CoreList::is_core($name);
		
		warn "Looking up $name $version\n";
		my $mod  = eval {
			$mcpan->module($name);
		};
		
		next unless $mod;
		
		my $release;
		if ($version) {
			$release = $mcpan->release($mod->distribution);
		}
		else {
			$release = $mcpan->release(sprintf("%s/%s-%s", $mod->author, $mod->distribution, $mod->version));
		}
				
		my %modules = map  { $_->{module} => $_->{version} }
		              grep { $_->{phase} ne 'develop' && $_->{relationship} eq 'requires' }
			      @{$release->dependency};
		
		my $data = {};
		$tree->{$name} = $seen->{$name} = $data;
		my $kids = $self->build_dependency_tree(\%modules, $seen);
		
		%$data = (
			name    => $name,
			version => $version,
			kids    => $kids,
			url     => $release->download_url,
		);
	}
	
	return $tree;
}

sub walk_tree {
	my ($self, $tree) = @_;

	$self->_do_tree_walk($tree, {});
	
	$self->runner->finish();
}

sub _do_tree_walk {
	my ($self, $tree, $seen) = @_;
	
	foreach my $name (sort keys %$tree) {
		next if $seen->{$name}++;
		my $data = $tree->{$name};
		
		if (%{$data->{kids}}) {
			$self->_do_tree_walk($data->{kids}, $seen);
		}
		
		$self->runner->run(sub {
			my $sleep = rand(55) + 5;
			print "[$$] starting $data->{name} - $data->{version} (sleep: $sleep)\n";
			sleep($sleep);
			print "[$$] done with $data->{name} - $data->{version}\n";
		});
	}
}

sub _build_runner {
	my ($self) = @_;
	
	return Parallel::Runner->new($self->workers);
}

sub _build_metacpan_client {
	my ($self) = @_;
	
	if ($self->cache) {
		return MetaCPAN::Client->new(
			ua => HTTP::Tiny::Mech->new(
				mechua => WWW::Mechanize::Cached->new(
					cache => CHI->new(
						driver   => 'File',
						root_dir => 'metacpan-cache',
					),
				),
			),
		);
	}
	else {
		return MetaCPAN::Client->new;
	}
}

=head1 TODO

=over 2

=item *

Doesn't actually install yet.

=back

=head1 AUTHORS

    Chris Reinhardt
    crein@cpan.org
    
=head1 COPYRIGHT

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=head1 SEE ALSO

L<cpanm>, L<Module::CPANfile>, L<MetaCPAN::Client>

=cut

1;
__END__
