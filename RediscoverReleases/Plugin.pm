package Plugins::RediscoverReleases::Plugin;

# Rediscover Releases: a list of random releases from the local library that prefers albums without recent plays.
# The list is built every few hours (not on every request) and kept in the prefs, so it stays the same between
# rebuilds and across server restarts. It is shown as a Material skin home row (HomeExtras.pm) and can be read by
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
my @LIST_PREFS = qw(count months includeUnplayed minPlayedPct genres partialAs);

sub initPlugin {
	my $class = shift;

	$prefs->init({
		count           => 250,
		months          => 12,
		includeUnplayed => 1,
		minPlayedPct    => 20,
		genres          => [],          # genre names; empty = all genres
		partialAs       => 'unplayed',  # 'unplayed' or 'played'
		rebuildHours    => 24,
		# state, not settings
		list            => [],          # album IDs, in display order
		builtAt         => 0,
		version         => 0,
	});

	$prefs->setValidate({ validator => 'intlimit', low => 10, high => 1000 }, 'count');
	$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 99   }, 'months');
	$prefs->setValidate({ validator => 'intlimit', low => 0,  high => 100  }, 'minPlayedPct');
	$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 999  }, 'rebuildHours');
	$prefs->setValidate({ validator => sub { $_[1] && ($_[1] eq 'unplayed' || $_[1] eq 'played') } }, 'partialAs');

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
}

sub shutdownPlugin {
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
