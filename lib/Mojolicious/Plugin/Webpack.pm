package Mojolicious::Plugin::Webpack;
use Mojo::Base 'Mojolicious::Plugin';

use Carp 'confess';
use Mojo::ByteStream 'b';
use Mojo::File 'path';
use Mojo::IOLoop::Subprocess;
use Mojo::JSON;
use Mojo::Path;

our $VERSION = '0.01';

sub assets_dir { shift->{assets_dir} }
sub daemon     { shift->{daemon} }

has dependencies => sub {
  return {
    core => [qw(webpack-cli webpack webpack-md5-hash html-webpack-plugin)],
    css  => [qw(css-loader mini-css-extract-plugin optimize-css-assets-webpack-plugin)],
    js   => [qw(@babel/core @babel/preset-env babel-loader uglifyjs-webpack-plugin)],
    sass => [qw(node-sass sass-loader)],
    vue  => [qw(vue vue-loader vue-template-compiler)],
  };
};

sub out_dir { shift->{out_dir} }
sub route   { shift->{route} }

sub register {
  my ($self, $app, $config) = @_;
  my $helper = $config->{helper} || 'asset';

  # TODO: Not sure if this should be global or not
  $ENV{NODE_ENV} ||= $app->mode eq 'development' ? 'development' : 'production';

  $self->{$_} = $config->{$_} // 1 for qw(auto_cleanup source_maps);
  $self->{process} = $config->{process} || ['js'];
  $self->{route} ||= $app->routes->route('/asset/*name')->via(qw(HEAD GET))->name('webpack.asset');

  $self->{$_} = path $config->{$_} for grep { $config->{$_} } qw(assets_dir out_dir);
  $self->{assets_dir} ||= path $app->home->rel_file('assets');
  $self->{out_dir} ||= $self->_build_out_dir($app);

  $self->dependencies->{$_} = $config->{dependencies}{$_} for keys %{$config->{dependencies} || {}};
  $self->_run_webpack($app) if $ENV{MOJO_WEBPACK_ARGS} // 1;
  $self->_register_assets;
  $app->helper($helper => sub { @_ == 1 ? $self : $self->_render_tag(@_) });
}

sub _build_out_dir {
  my ($self, $app) = @_;
  my $path = Mojo::Path->new($self->route->render({name => 'name.ext'}));
  pop @$path;
  return path $app->static->paths->[0], @$path;
}

sub _environment_variables {
  my $self = shift;
  my %env  = %ENV;

  $env{WEBPACK_ASSETS_DIR} = $self->assets_dir;
  $env{WEBPACK_OUT_DIR}    = $self->out_dir;
  $env{WEBPACK_SHARE_DIR}   //= $self->_share_dir;
  $env{WEBPACK_SOURCE_MAPS} //= $self->{source_maps} // 1;
  $env{uc "WEBPACK_RULE_FOR_$_"} = 1 for @{$self->{process}};

  return \%env;
}

sub _install_node_deps {
  my ($self, $app) = @_;
  my $package_json = Mojo::JSON::decode_json($app->home->rel_file('package.json')->slurp);
  my $n            = 0;

  system qw(npm install) if %{$package_json->{dependencies}} and !-d $app->home->rel_file('node_modules');

  for my $preset ('core', @{$self->{process}}) {
    for my $module (@{$self->dependencies->{$preset} || []}) {
      next if $package_json->{dependencies}{$module};
      warn "[Webpack] npm install $module\n" if $ENV{MOJO_WEBPACK_DEBUG};
      system npm => install => $module;
      $n++;
    }
  }

  return $n;
}

sub _render_tag {
  my ($self, $c, $name, @args) = @_;
  my $asset = $self->{assets}{$name} or confess "Invalid asset name $name";
  $asset->[0]->{src} = $c->url_for('webpack.asset', {name => $asset->[1]});
  return b $asset->[0];
}

sub _render_to_file {
  my ($self, $app, $name, $out_file) = @_;
  my $is_generated = '';

  eval {
    $out_file ||= $app->home->rel_file($name);
    my $CFG = $out_file->open('<');
    /Autogenerated\s*by\s*Mojolicious-Plugin-Webpack/i and $is_generated = $_ while <$CFG>;
  };

  return 'custom' if !$is_generated and -r $out_file;
  return 'current' if $is_generated =~ /\b$VERSION\b/;

  my $template = $self->_share_dir->child($name)->slurp;
  $template =~ s!__AUTOGENERATED__!Autogenerated by Mojolicious-Plugin-Webpack $VERSION!g;
  $template =~ s!__NAME__!{$app->moniker}!ge;
  $template =~ s!__VERSION__!{$app->VERSION || '0.0.1'}!ge;
  $out_file->spurt($template);
  return 'generated';
}

sub _register_assets {
  my $self = shift;

  my $path_to_markup = $self->out_dir->child(sprintf 'webpack.%s.html',
    $ENV{WEBPACK_CUSTOM_NAME} || ($ENV{NODE_ENV} ne 'production' ? 'development' : 'production'));
  my $markup = Mojo::DOM->new($path_to_markup->slurp);

  $markup->find('link, script')->each(sub {
    my $tag = shift;
    my $src = $tag->{src} || $tag->{href};
    $self->{assets}{"$1.$2"} = [$tag, $src] if $src =~ m!(.*)\.\w+\.(css|js)$!i;
  });
}

sub _run_webpack {
  my ($self, $app) = @_;
  my $config_file = $app->home->rel_file('webpack.config.js');
  my $env         = $self->_environment_variables;

  $self->_render_to_file($app, 'package.json');
  $self->_render_to_file($app, 'webpack.config.js');
  $self->_render_to_file($app, 'webpack.custom.js',
    $self->assets_dir->child(sprintf 'webpack.%s.js', $ENV{WEBPACK_CUSTOM_NAME} || 'custom'));
  $self->_install_node_deps($app);

  unless (-e $env->{WEBPACK_OUT_DIR}) {
    path($env->{WEBPACK_OUT_DIR})->make_path;
  }
  unless (-w $env->{WEBPACK_OUT_DIR}) {
    warn "[Webpack] Cannot write to $env->{WEBPACK_OUT_DIR}\n" if $ENV{MOJO_WEBPACK_DEBUG};
    return;
  }

  my @cmd = $env->{WEBPACK_BINARY} || $app->home->rel_file('node_modules/.bin/webpack');
  push @cmd, '--config' => $config_file->to_string;
  push @cmd, '--progress', '--profile', '--verbose' if $ENV{MOJO_WEBPACK_VERBOSE};
  push @cmd, split /\s+/, +($ENV{MOJO_WEBPACK_ARGS} || '');

  warn "[Webpack] @cmd\n" if $ENV{MOJO_WEBPACK_DEBUG};
  map { warn "[Webpack] $_=$env->{$_}\n" } grep {/^WEBPACK_/} sort keys %$env if $ENV{MOJO_WEBPACK_DEBUG};
  local %ENV = %$env;
  return system @cmd unless grep {/--watch/} @cmd;
  $self->{daemon} = Mojo::IOLoop::Subprocess->new->run(sub { %ENV = %$env; system @cmd }, sub { });
}

sub _share_dir {
  state $share = path(path(__FILE__)->dirname, 'Webpack');
}

1;
