use lib '.';
use t::Helper;

plan skip_all => 'TEST_NODE_MODULES=1' unless $ENV{TEST_NODE_MODULES} or $ENV{TEST_ALL};

my $cwd   = t::Helper->cwd('install-deps');
my $t     = t::Helper->t(args => '', dependencies => {core => ['underscore'], js => []});
my $asset = $t->app->asset;

is $asset->_render_to_file($t->app, 'package.json'), 'generated', 'generated package.json';

$asset->dependencies->{core} = ['underscore'];
$asset->dependencies->{js}   = [];
is $asset->_install_node_deps($t->app), 1, 'first run';
is $asset->_install_node_deps($t->app), 0, 'second run';

$t = t::Helper->t(args => '', dependencies => {core => ['underscore'], js => []}, process => [qw(js css)]);
$asset = $t->app->asset;

$asset->{process} = [qw(js css)];
is $asset->_install_node_deps($t->app), 3, 'more deps for css';
is $asset->_install_node_deps($t->app), 0, 'all done';

done_testing;
