package Plugins::RediscoverReleases::Plugin;

# Rediscover Releases: a list of random releases from the local library that prefers albums without recent plays.
# The list is built every few hours (not on every request) and kept in the prefs, so it stays the same between
# rebuilds and across server restarts. It is shown as a Material skin home row (HomeExtras.pm), as an entry in the
# "My Music" browse menu (also one of Material's browse modes), can feed Don't Stop The Music, and can be read by
# other clients with the "rediscoverreleases" CLI query (see README.md).

use strict;

use Scalar::Util qw(blessed);

use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::RediscoverReleases::List;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.rediscoverreleases',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_REDISCOVER_RELEASES',
});

my $prefs = preferences('plugin.rediscoverreleases');

# Prefs that change which albums are chosen: a change rebuilds the list.
my @LIST_PREFS = qw(count months includeUnplayed minPlayedPct genres genreFilter libraryId libraryMatch minRating includeUnrated partialAs);

sub initPlugin {
	my $class = shift;

	$prefs->init({
		count           => 250,
		months          => 12,
		includeUnplayed => 1,
		minPlayedPct    => 20,
		genres          => [],          # genre names, for genreFilter
		# 'all', 'include' or 'exclude' the selected genres (before 1.1: genres set = include)
		genreFilter     => (@{ $prefs->get('genres') || [] } ? 'include' : 'all'),
		libraryId       => '',          # Library View; '' = none
		libraryMatch    => 'any',       # an album counts as in the view with 'any' or 'all' of its tracks in it
		minRating       => 0,           # minimum average rating of the rated tracks (0-100, 20 = 1 star); 0 = off
		includeUnrated  => 1,           # with minRating: albums without rated tracks
		partialAs       => 'unplayed',  # 'unplayed' or 'played'
		rebuildHours    => 24,
		dstmAlbums      => 1,           # albums added at a time by Don't Stop The Music
		# state, not settings
		list            => [],          # album IDs, in display order
		builtAt         => 0,
		version         => 0,
	});

	$prefs->setValidate({ validator => 'intlimit', low => 10, high => 1000 }, 'count');
	$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 99   }, 'months');
	$prefs->setValidate({ validator => 'intlimit', low => 0,  high => 100  }, 'minPlayedPct');
	$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 999  }, 'rebuildHours');
	$prefs->setValidate({ validator => 'intlimit', low => 0,  high => 100  }, 'minRating');
	$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 10   }, 'dstmAlbums');
	$prefs->setValidate({ validator => sub { $_[1] && ($_[1] eq 'unplayed' || $_[1] eq 'played') } }, 'partialAs');
	$prefs->setValidate({ validator => sub { $_[1] && $_[1] =~ /^(?:all|include|exclude)$/ } }, 'genreFilter');
	$prefs->setValidate({ validator => sub { $_[1] && $_[1] =~ /^(?:any|all)$/ } }, 'libraryMatch');
	$prefs->setValidate({ validator => sub { !defined $_[1] || $_[1] =~ /^[A-Za-z0-9_-]*$/ } }, 'libraryId');

	# Saving the settings page sets every pref at once: rebuild once, shortly after.
	$prefs->setChange(sub {
		Slim::Utils::Timers::killTimers(undef, \&_rebuildAfterSettings);
		Slim::Utils::Timers::setTimer(undef, time() + 2, \&_rebuildAfterSettings);
	}, @LIST_PREFS);
	$prefs->setChange(sub { Plugins::RediscoverReleases::List::scheduleRebuild() }, 'rebuildHours');

	if (main::WEBUI) {
		require Plugins::RediscoverReleases::Settings;
		Plugins::RediscoverReleases::Settings->new();
	}

	#                                                                          |requires client
	#                                                                          |  |is a query
	#                                                                          |  |  |has tags
	#                                                                          |  |  |  |function
	Slim::Control::Request::addDispatch(['rediscoverreleases', 'albums', '_index', '_quantity'], [0, 1, 1, \&_cliAlbums]);
	Slim::Control::Request::addDispatch(['rediscoverreleases', 'status'],                         [0, 1, 1, \&_cliStatus]);
	Slim::Control::Request::addDispatch(['rediscoverreleases', 'regenerate'],                     [0, 0, 1, \&_cliRegenerate]);

	Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);
	Slim::Control::Request::subscribe(\&_onRescanDone, [['rescan'], ['done']]);

	Plugins::RediscoverReleases::List::init();

	require Plugins::RediscoverReleases::Browse;
	Plugins::RediscoverReleases::Browse::init();

	$class->SUPER::initPlugin(@_);
}

sub postinitPlugin {
	my $class = shift;

	if (Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
			&& Plugins::MaterialSkin::Plugin->can('registerHomeExtra')) {
		eval { require Plugins::RediscoverReleases::HomeExtras; };
		$log->error("Could not register the Material home row: $@") if $@;
	} else {
		$log->warn('Material skin not found (or too old): the Rediscover Releases row needs it');
	}

	if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_REDISCOVER_RELEASES_DSTM', \&_dontStopTheMusic);
	}
}

# Don't Stop The Music: tracks of random albums from the list that aren't in the queue yet, from the player's
# Library View if it has one.
sub _dontStopTheMusic {
	my ($client, $cb) = @_;
	my %inQueue;
	foreach my $track (@{ Slim::Player::Playlist::playList($client) || [] }) {
		$inQueue{$track->albumid} = 1 if blessed($track) && $track->can('albumid') && $track->albumid;
	}
	my $libraryId = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$cb->($client, Plugins::RediscoverReleases::List::mixTracks($prefs->get('dstmAlbums') || 1, \%inQueue, $libraryId));
}

sub shutdownPlugin {
	if (Slim::Plugin::DontStopTheMusic::Plugin->can('unregisterHandler')) {
		Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('PLUGIN_REDISCOVER_RELEASES_DSTM');
	}
	Slim::Control::Request::unsubscribe(\&_onNewSong);
	Slim::Control::Request::unsubscribe(\&_onRescanDone);
}

sub _rebuildAfterSettings {
	main::INFOLOG && $log->is_info && $log->info('Settings changed: rebuilding the list');
	Plugins::RediscoverReleases::List::rebuild('settings changed');
}

# A song of a listed album started: it may have been played in full now (see List::markPlayed).
sub _onNewSong {
	my $request = shift;
	my $client = $request->client() || return;
	my $song = $client->playingSong() || return;
	my $track = $song->currentTrack() || return;
	return unless blessed($track) && $track->can('albumid');
	Plugins::RediscoverReleases::List::markPlayed($track->albumid);
}

sub _onRescanDone {
	Plugins::RediscoverReleases::List::afterRescan();
}

# rediscoverreleases albums <start> <count> [tags:<albums query tags>] [library_id:<id>]
# The list in its order, with the same fields as LMS's "albums" query for these tags. With library_id, only the
# listed albums that have tracks in that library (count = that number).
sub _cliAlbums {
	my $request = shift;

	my $index    = $request->getParam('_index') || 0;
	my $quantity = $request->getParam('_quantity');
	my $tags     = $request->getParam('tags') || 'ajlsy';
	my $libId    = $request->getParam('library_id');

	my $albums = Plugins::RediscoverReleases::List::albums($tags, $libId);
	my $count = scalar @$albums;
	$quantity = $count unless defined $quantity && $quantity =~ /^\d+$/;

	$request->addResult('count', $count);
	$request->addResult('version', $prefs->get('version'));
	$request->addResult('built', $prefs->get('builtAt'));

	my $cnt = 0;
	for (my $i = $index; $i < $count && $cnt < $quantity; $i++) {
		$request->addResultLoop('albums_loop', $cnt, $_, $albums->[$i]->{$_}) for keys %{$albums->[$i]};
		$cnt++;
	}

	$request->setStatusDone();
}

# rediscoverreleases status: plugin version, list size and timing (all epoch seconds).
sub _cliStatus {
	my $request = shift;

	Plugins::RediscoverReleases::List::cleanup();
	$request->addResult('plugin_version', __PACKAGE__->_pluginDataFor('version'));
	$request->addResult('count', scalar @{ $prefs->get('list') || [] });
	$request->addResult('version', $prefs->get('version'));
	$request->addResult('built', $prefs->get('builtAt'));
	$request->addResult('next', Plugins::RediscoverReleases::List::nextRebuild());
	$request->setStatusDone();
}

sub _cliRegenerate {
	my $request = shift;
	Plugins::RediscoverReleases::List::rebuild('CLI');
	$request->addResult('count', scalar @{ $prefs->get('list') || [] });
	$request->setStatusDone();
}

1;
