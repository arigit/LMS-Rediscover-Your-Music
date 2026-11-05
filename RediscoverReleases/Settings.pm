package Plugins::RediscoverReleases::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::DateTime;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::RediscoverReleases::List;

my $prefs = preferences('plugin.rediscoverreleases');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_REDISCOVER_RELEASES') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/RediscoverReleases/settings.html') }

sub prefs {
	return ($prefs, qw(count months includeUnplayed minPlayedPct partialAs rebuildHours));
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{saveSettings}) {
		# Genres: "all" checkbox, or one checkbox per genre (genre_<n>, value = name).
		my @genres;
		unless ($params->{allGenres}) {
			@genres = sort map { $params->{$_} } grep { /^genre_\d+$/ } keys %$params;
		}
		my $old = join("\x00", sort @{ $prefs->get('genres') || [] });
		$prefs->set('genres', \@genres) if $old ne join("\x00", @genres);
	}

	return $class->SUPER::handler($client, $params);
}

# After the prefs are saved (the form always saves; "Regenerate" is a second submit button), before the page is drawn.
sub beforeRender {
	my ($class, $params) = @_;

	if ($params->{regenerate}) {
		# also covers a settings change saved with it
		Slim::Utils::Timers::killTimers(undef, \&Plugins::RediscoverReleases::Plugin::_rebuildAfterSettings);
		Plugins::RediscoverReleases::List::rebuild('settings page');
		$params->{warning} = string('PLUGIN_REDISCOVER_RELEASES_REGENERATED');
	}

	my %selected = map { $_ => 1 } @{ $prefs->get('genres') || [] };
	my $i = 0;
	$params->{genreList} = [ map { { id => $i++, name => $_->[0], albums => $_->[1], selected => $selected{$_->[0]} ? 1 : 0 } }
		@{ Plugins::RediscoverReleases::List::genres() } ];
	$params->{allGenres} = %selected ? 0 : 1;

	my $built = $prefs->get('builtAt');
	my $stats = $prefs->get('stats') || {};
	$params->{listCount} = scalar @{ $prefs->get('list') || [] };
	$params->{builtAt}   = $built ? Slim::Utils::DateTime::shortDateF($built) . ' ' . Slim::Utils::DateTime::timeF($built) : '';
	my $next = Plugins::RediscoverReleases::List::nextRebuild();
	$params->{nextAt}    = $built ? Slim::Utils::DateTime::shortDateF($next) . ' ' . Slim::Utils::DateTime::timeF($next) : '';
	$params->{stats}     = $stats;
}

1;
