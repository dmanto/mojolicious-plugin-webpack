package t::Helper;
use Mojo::Base -strict;

use Mojo::File 'path';
use Mojolicious;
use Test::Mojo;
use Test::More;

$ENV{WEBPACK_AUTO_CLEANUP} = 0;
our ($CLEANUP, $OLD_DIR, $WORK_DIR) = (0, path, path);

sub t {
  my ($class, %config) = @_;
  my $app = Mojolicious->new;
  $ENV{MOJO_WEBPACK_ARGS} = delete $config{args} if defined $config{args};
  $ENV{WEBPACK_CUSTOM_NAME} = path($0)->basename('.t');
  $app->plugin(Webpack => \%config);
  return Test::Mojo->new($app);
}

sub cwd {
  my ($class, @path) = @_;
  $CLEANUP = @path ? 1 : 0;
  mkdir($WORK_DIR = path(path(__FILE__)->dirname, @path)->to_abs);
  plan skip_all => "Cannot change to $WORK_DIR" unless chdir $WORK_DIR;
  $ENV{MOJO_HOME} = $WORK_DIR;
  return $WORK_DIR;
}

sub import {
  my $class  = shift;
  my $caller = caller;

  $_->import for qw(strict warnings utf8);
  feature->import(':5.10');

  eval <<"HERE" or die $@;
package $caller;
use Test::Mojo;
use Test::More;
1;
HERE
}

1;

END {
  chdir $OLD_DIR if $OLD_DIR;
  $WORK_DIR->remove_tree if $WORK_DIR and $CLEANUP;
}