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
	return ($prefs, qw(count months includeUnplayed minPlayedPct genreFilter libraryId libraryMatch minRating includeUnrated
		partialAs rebuildHours dstmAlbums));
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{saveSettings}) {
		# An unticked checkbox posts nothing, which LMS saves as undef; the plugin's defaults (on) would then turn
		# it back on at the next server start. Save 0 instead.
		foreach my $pref (qw(includeUnplayed includeUnrated)) {
			$params->{"pref_$pref"} = 0 unless $params->{"pref_$pref"};
		}

		# One checkbox per genre (genre_<n>, value = name). Kept with "All genres" too, for switching back.
		my @genres = sort map { $params->{$_} } grep { /^genre_\d+$/ } keys %$params;
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
	$params->{genreFilter} = Plugins::RediscoverReleases::List::genreFilter();

	my $libraryId = $prefs->get('libraryId') || '';
	$params->{libraryList} = Plugins::RediscoverReleases::List::libraries();
	my $known = grep { $_->[0] eq $libraryId } @{ $params->{libraryList} };
	# Not among LMS's named views: still used while its tracks are there (List::libraryExists), shown by its ID
	$params->{libraryMissing} = ($libraryId && !$known) ? $libraryId : '';
	$params->{libraryGone} = ($libraryId && !$known && !Plugins::RediscoverReleases::List::libraryExists($libraryId)) ? 1 : 0;

	# Ratings in half stars, as 0-100 (Ratings Light and LMS store 20 per star)
	$params->{ratingChoices} = [ map { { value => $_ * 10, stars => $_ / 2 } } 1 .. 10 ];

	my $built = $prefs->get('builtAt');
	my $stats = $prefs->get('stats') || {};
	$params->{listCount} = scalar @{ $prefs->get('list') || [] };
	$params->{builtAt}   = $built ? Slim::Utils::DateTime::shortDateF($built) . ' ' . Slim::Utils::DateTime::timeF($built) : '';
	my $next = Plugins::RediscoverReleases::List::nextRebuild();
	$params->{nextAt}    = $built ? Slim::Utils::DateTime::shortDateF($next) . ' ' . Slim::Utils::DateTime::timeF($next) : '';
	$params->{stats}     = $stats;
}

1;
