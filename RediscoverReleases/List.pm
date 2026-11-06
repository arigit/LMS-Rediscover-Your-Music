package Plugins::RediscoverReleases::List;

# Builds and keeps the Rediscover list.
#
# Each album's play state comes from LMS's per-track play data (tracks_persistent: playcount, lastplayed):
#  - every track played: "played", last played = the OLDEST of its tracks' last plays (so an album counts as
#    recently played only once all of it has been heard recently);
#  - no track played: "unplayed";
#  - some tracks played: as the partialAs setting says; as "played", last played = the oldest last play of its
#    played tracks.
#
# Filters (all optional): genres (albums with any track of the selected genres, or all albums except those with any
# track of them), a Library View (albums with any, or all, of their tracks in it), and a minimum average rating
# (over the album's rated tracks; albums without rated tracks per includeUnrated). Play state always uses all of an
# album's tracks.
#
# Selection (count N, months M, minimum played share P%):
#  1. "old" = played albums not played in the last M months; "recent" = played within M months; "unplayed".
#  2. At least ceil(N * P / 100) albums come from "old" (topped up from "recent", least recently played first,
#     if "old" is too small).
#  3. The rest is drawn at random from the remaining "old" and (if included) "unplayed" albums.
#  4. Still short (small library): least recently played "recent" albums.
#  5. Shuffled, so played and unplayed albums are mixed.
#
# Played in full: when a song of a listed album starts, the album is marked (in memory, a hash lookup per song).
# A cleanup checks only the marked albums: an album whose tracks have all been played since the list was built
# is removed. The cleanup runs at most every CLEANUP_DELAY seconds while albums are marked (then Material is told
# to refresh its home rows), and before the list is served, so a client never gets an album that is already done.
# Removed albums are not replaced until the next rebuild.

use strict;

use List::Util qw(shuffle min);
use POSIX qw(ceil);
use Time::HiRes;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant CLEANUP_DELAY => 300;   # seconds after the first play of a listed album
use constant STARTUP_DELAY => 60;    # first check after server start
use constant SCAN_RETRY    => 300;   # retry while the library is being scanned
use constant CHUNK         => 100;   # album IDs per "albums" query

my $log   = logger('plugin.rediscoverreleases');
my $prefs = preferences('plugin.rediscoverreleases');

my %listed;     # album ID => 1, for the newsong check
my %marked;     # listed album IDs with a song started since the last cleanup
my $cleanupPending = 0;
my $retryWhy;   # reason of a rebuild put off by a library scan

sub init {
	_indexList();
	Slim::Utils::Timers::setTimer(undef, time() + STARTUP_DELAY, \&_checkRebuild);
}

sub _indexList {
	%listed = map { $_ => 1 } @{ $prefs->get('list') || [] };
}

sub nextRebuild {
	return ($prefs->get('builtAt') || 0) + $prefs->get('rebuildHours') * 3600;
}

# (Re)arm the rebuild timer for the current list's age and the rebuildHours setting.
sub scheduleRebuild {
	Slim::Utils::Timers::killTimers(undef, \&_checkRebuild);
	my $when = nextRebuild();
	$when = time() + 1 if $when < time() + 1;
	Slim::Utils::Timers::setTimer(undef, $when, \&_checkRebuild);
}

sub _checkRebuild {
	Slim::Utils::Timers::killTimers(undef, \&_checkRebuild);
	if (time() >= nextRebuild() || !scalar @{ $prefs->get('list') || [] }) {
		return if !rebuild('scheduled');
	}
	scheduleRebuild();
}

# Build a new list now. Returns 1 if built, 0 if put off (library scan running, or failed: retried later).
sub rebuild {
	my $why = shift;

	if (Slim::Music::Import->stillScanning()) {
		main::INFOLOG && $log->is_info && $log->info("Library scan running: rebuild ($why) in " . SCAN_RETRY . ' s');
		$retryWhy = $why;
		Slim::Utils::Timers::killTimers(undef, \&_checkRebuild);
		Slim::Utils::Timers::killTimers(undef, \&_retryRebuild);
		Slim::Utils::Timers::setTimer(undef, time() + SCAN_RETRY, \&_retryRebuild);
		return 0;
	}

	my $start = Time::HiRes::time();
	my $ids = eval { _select() };
	if ($@ || !$ids) {
		$log->error("Failed to build the list (retrying in " . SCAN_RETRY . " s): $@");
		$retryWhy = $why;
		Slim::Utils::Timers::killTimers(undef, \&_checkRebuild);
		Slim::Utils::Timers::killTimers(undef, \&_retryRebuild);
		Slim::Utils::Timers::setTimer(undef, time() + SCAN_RETRY, \&_retryRebuild);
		return 0;
	}

	$prefs->set('list', $ids);
	$prefs->set('builtAt', time());
	$prefs->set('version', ($prefs->get('version') || 0) + 1);
	%marked = ();
	_indexList();
	scheduleRebuild();

	main::INFOLOG && $log->is_info && $log->info(sprintf('Built the list (%s): %d albums in %.2f s', $why, scalar @$ids, Time::HiRes::time() - $start));
	_signalMaterial();
	return 1;
}

sub _retryRebuild {
	scheduleRebuild() if rebuild($retryWhy || 'retry');
}

sub _select {
	my $count     = $prefs->get('count');
	my $months    = $prefs->get('months');
	my $partialAs = $prefs->get('partialAs') || 'unplayed';
	my $cutoff    = _monthsAgo($months);

	my $minRating      = $prefs->get('minRating') || 0;
	my $includeUnrated = $prefs->get('includeUnrated');

	my $stats = albumStats();
	my (@old, @recent, @unplayed);
	my $belowRating = 0;
	foreach my $album (@$stats) {
		my ($id, $tracks, $played, $oldest, $rated, $rating) = @$album;
		if ($minRating && ($rated ? $rating < $minRating : !$includeUnrated)) {
			$belowRating++;
			next;
		}
		if (!$played || ($played < $tracks && $partialAs ne 'played')) {
			push @unplayed, $id;
		} elsif (defined $oldest && $oldest < $cutoff) {
			push @old, $id;
		} else {
			push @recent, [$id, $oldest || 0];
		}
	}
	my %stats = (old => scalar @old, recent => scalar @recent, unplayed => scalar @unplayed, belowRating => $belowRating);
	# least recently played first
	my @recentIds = map { $_->[0] } sort { $a->[1] <=> $b->[1] } @recent;
	@old = shuffle(@old);

	my @chosen;
	my $quota = min($count, ceil($count * $prefs->get('minPlayedPct') / 100));
	push @chosen, splice(@old, 0, min($quota, scalar @old));
	push @chosen, splice(@recentIds, 0, min($quota - scalar @chosen, scalar @recentIds)) if @chosen < $quota;

	my @rest = shuffle(@old, $prefs->get('includeUnplayed') ? @unplayed : ());
	push @chosen, splice(@rest, 0, min($count - scalar @chosen, scalar @rest)) if @chosen < $count;
	push @chosen, splice(@recentIds, 0, min($count - scalar @chosen, scalar @recentIds)) if @chosen < $count;

	my %unplayedSet = map { $_ => 1 } @unplayed;
	$stats{chosenUnplayed} = scalar grep { $unplayedSet{$_} } @chosen;
	$stats{chosen} = scalar @chosen;
	$prefs->set('stats', \%stats);

	main::INFOLOG && $log->is_info && $log->info(sprintf('Albums: %d not played for %d months, %d played since, %d unplayed%s; chose %d (%d unplayed)',
		$stats{old}, $months, $stats{recent}, $stats{unplayed}, $prefs->get('includeUnplayed') ? '' : ' (not included)',
		$stats{chosen}, $stats{chosenUnplayed}));

	return [ shuffle(@chosen) ];
}

sub _monthsAgo {
	my $months = shift;
	my @t = localtime();
	$t[4] -= $months;   # mktime normalises a negative month
	return POSIX::mktime(@t[0..5]) || (time() - $months * 30 * 86400);
}

# [album ID, tracks, played tracks, oldest last play of the played tracks, rated tracks, average rating of the rated
# tracks (0-100)] for every album that passes the genre and Library View filters.
sub albumStats {
	my $dbh = Slim::Schema->dbh;
	my @genres = @{ $prefs->get('genres') || [] };
	my $genreFilter = genreFilter();
	my ($libraryId, $libraryMatch) = libraryFilter();

	my $sql = q{
		SELECT tracks.album,
		       COUNT(*),
		       SUM(CASE WHEN tracks_persistent.playcount > 0 THEN 1 ELSE 0 END),
		       MIN(CASE WHEN tracks_persistent.playcount > 0 THEN tracks_persistent.lastplayed END),
		       SUM(CASE WHEN tracks_persistent.rating > 0 THEN 1 ELSE 0 END),
		       AVG(CASE WHEN tracks_persistent.rating > 0 THEN tracks_persistent.rating END)
		FROM tracks
		LEFT JOIN tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
		WHERE tracks.audio = 1 AND tracks.album IS NOT NULL
	};
	my @bind;
	if ($genreFilter ne 'all' && @genres) {
		$sql .= ' AND tracks.album ' . ($genreFilter eq 'exclude' ? 'NOT IN' : 'IN')
		      . ' (SELECT DISTINCT t2.album FROM tracks t2'
		      . ' JOIN genre_track ON genre_track.track = t2.id'
		      . ' JOIN genres ON genres.id = genre_track.genre'
		      . ' WHERE t2.album IS NOT NULL AND genres.name IN (' . join(',', map { '?' } @genres) . '))';
		# The database holds UTF-8 bytes (LMS's own queries decode and encode like this too).
		push @bind, map { my $g = $_; utf8::encode($g) if utf8::is_utf8($g); $g } @genres;
	}
	if ($libraryId) {
		$sql .= ' AND tracks.album IN (SELECT t3.album FROM tracks t3 JOIN library_track lt3 ON lt3.track = t3.id'
		      . ' WHERE lt3.library = ? AND t3.album IS NOT NULL)';
		push @bind, $libraryId;
		if ($libraryMatch eq 'all') {
			$sql .= ' AND tracks.album NOT IN (SELECT t4.album FROM tracks t4'
			      . ' LEFT JOIN library_track lt4 ON lt4.track = t4.id AND lt4.library = ?'
			      . ' WHERE t4.audio = 1 AND t4.album IS NOT NULL AND lt4.track IS NULL)';
			push @bind, $libraryId;
		}
	}
	$sql .= ' GROUP BY tracks.album';

	return $dbh->selectall_arrayref($sql, undef, @bind) || [];
}

# 'all', 'include' or 'exclude' (the selected genres). Before 1.1 there was no mode: genres set = include.
sub genreFilter {
	my $filter = $prefs->get('genreFilter');
	return $filter if $filter && $filter =~ /^(?:all|include|exclude)$/;
	return @{ $prefs->get('genres') || [] } ? 'include' : 'all';
}

# (Library View ID, 'any' or 'all'), or () without one. A view that no longer exists is ignored (logged).
sub libraryFilter {
	my $id = $prefs->get('libraryId');
	return () unless $id;
	if (!libraryExists($id)) {
		$log->warn("Library View $id not found: not filtering by it");
		return ();
	}
	return ($id, ($prefs->get('libraryMatch') || 'any') eq 'all' ? 'all' : 'any');
}

sub libraryExists {
	my $id = shift;
	my $libraries = Slim::Music::VirtualLibraries->getLibraries() || {};
	return 1 if $libraries->{$id};
	# also the tables, for the tests and while the views are being built
	return Slim::Schema->dbh->selectrow_array('SELECT 1 FROM library_track WHERE library = ? LIMIT 1', undef, $id) ? 1 : 0;
}

# The listed album IDs that have a track in this Library View (all of them without one).
sub inLibrary {
	my ($ids, $libraryId) = @_;
	return $ids unless $libraryId && $libraryId ne '-1' && $libraryId ne '0' && @$ids;
	my $dbh = Slim::Schema->dbh;
	my %in;
	for (my $i = 0; $i < @$ids; $i += CHUNK) {
		my @chunk = @$ids[$i .. min($i + CHUNK, scalar @$ids) - 1];
		my $rows = $dbh->selectcol_arrayref('SELECT DISTINCT tracks.album FROM tracks JOIN library_track ON library_track.track = tracks.id'
			. ' WHERE library_track.library = ? AND tracks.album IN (' . join(',', map { '?' } @chunk) . ')', undef, $libraryId, @chunk);
		$in{$_} = 1 for @$rows;
	}
	return [ grep { $in{$_} } @$ids ];
}

# For Don't Stop The Music: the track URLs of up to $count random listed albums (each in disc and track order),
# skipping albums in %$skip (e.g. those already in the queue) and, with a Library View ID, albums outside it.
sub mixTracks {
	my ($count, $skip, $libraryId) = @_;
	cleanup();
	my @candidates = grep { !$skip->{$_} } @{ inLibrary($prefs->get('list') || [], $libraryId) };
	my @albums = (shuffle(@candidates))[0 .. min($count, scalar @candidates) - 1];
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached(q{
		SELECT url FROM tracks WHERE album = ? AND audio = 1
		ORDER BY COALESCE(disc, 0), COALESCE(tracknum, 0), titlesort
	});
	my @urls;
	foreach my $album (@albums) {
		push @urls, @{ $dbh->selectcol_arrayref($sth, undef, $album) || [] };
	}
	main::INFOLOG && $log->is_info && $log->info('Don\'t Stop The Music: albums ' . join(',', @albums) . ', ' . scalar(@urls) . ' tracks');
	return \@urls;
}

# Library Views for the settings page: [[id, name], ...] by name.
sub libraries {
	my $libraries = Slim::Music::VirtualLibraries->getLibraries() || {};
	return [ sort { lc($a->[1]) cmp lc($b->[1]) } map { [ $_, $libraries->{$_}->{name} || $_ ] } keys %$libraries ];
}

# Library genres for the settings page: [[name, albums], ...] by name.
sub genres {
	my $dbh = Slim::Schema->dbh;
	my $rows = $dbh->selectall_arrayref(q{
		SELECT genres.name, COUNT(DISTINCT tracks.album)
		FROM genres
		JOIN genre_track ON genre_track.genre = genres.id
		JOIN tracks ON tracks.id = genre_track.track
		WHERE tracks.audio = 1
		GROUP BY genres.id
		ORDER BY genres.namesort
	}) || [];
	utf8::decode($_->[0]) for @$rows;
	return $rows;
}

# A song of this album started.
sub markPlayed {
	my $albumId = shift;
	return unless $albumId && $listed{$albumId};
	main::DEBUGLOG && $log->is_debug && $log->debug("Album $albumId of the list is playing");
	$marked{$albumId} = 1;
	# One timer for all marks: at most one cleanup per CLEANUP_DELAY.
	return if $cleanupPending;
	$cleanupPending = 1;
	Slim::Utils::Timers::setTimer(undef, time() + CLEANUP_DELAY, \&_cleanupTimer);
}

sub _cleanupTimer {
	$cleanupPending = 0;
	_signalMaterial() if cleanup();
}

# Remove marked albums that have been played in full since the list was built. Returns the number removed.
sub cleanup {
	return 0 unless %marked;
	return 0 if Slim::Music::Import->stillScanning();

	my $since = $prefs->get('builtAt') || 0;
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached(q{
		SELECT COUNT(*), SUM(CASE WHEN tracks_persistent.lastplayed >= ? THEN 1 ELSE 0 END)
		FROM tracks
		LEFT JOIN tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
		WHERE tracks.album = ? AND tracks.audio = 1
	});

	my %done;
	foreach my $albumId (keys %marked) {
		$sth->execute($since, $albumId);
		my ($tracks, $played) = $sth->fetchrow_array();
		$sth->finish();
		$done{$albumId} = 1 if $tracks && $played && $played >= $tracks;
	}
	%marked = ();
	return 0 unless %done;

	main::INFOLOG && $log->is_info && $log->info('Played in full, removed from the list: ' . join(',', sort keys %done));
	$prefs->set('list', [ grep { !$done{$_} } @{ $prefs->get('list') || [] } ]);
	$prefs->set('version', ($prefs->get('version') || 0) + 1);
	_indexList();
	return scalar keys %done;
}

# Album IDs change with a full rescan: drop the ones that are gone, and rebuild if most of the list went.
sub afterRescan {
	my @list = @{ $prefs->get('list') || [] };
	return unless @list;

	my $dbh = Slim::Schema->dbh;
	my %exists;
	for (my $i = 0; $i < @list; $i += CHUNK) {
		my @chunk = @list[$i .. min($i + CHUNK, scalar @list) - 1];
		my $rows = $dbh->selectcol_arrayref('SELECT id FROM albums WHERE id IN (' . join(',', map { '?' } @chunk) . ')', undef, @chunk);
		$exists{$_} = 1 for @$rows;
	}
	my @kept = grep { $exists{$_} } @list;
	return if @kept == @list;

	if (@kept < @list / 2) {
		rebuild('library rescanned');
	} else {
		main::INFOLOG && $log->is_info && $log->info(sprintf('Rescan: %d albums of the list are gone', @list - @kept));
		$prefs->set('list', \@kept);
		$prefs->set('version', ($prefs->get('version') || 0) + 1);
		_indexList();
		_signalMaterial();
	}
}

# The list as LMS "albums" query items (for these tags), in list order; with a library ID only its albums.
sub albums {
	my ($tags, $libId) = @_;

	cleanup();
	my @list = @{ $prefs->get('list') || [] };
	my %byId;
	for (my $i = 0; $i < @list; $i += CHUNK) {
		my @chunk = @list[$i .. min($i + CHUNK, scalar @list) - 1];
		my @cmd = ('albums', 0, scalar @chunk, 'album_id:' . join(',', @chunk), "tags:$tags");
		push @cmd, "library_id:$libId" if defined $libId && $libId ne '' && $libId ne '-1' && $libId ne '0';
		my $request = Slim::Control::Request::executeRequest(undef, \@cmd);
		foreach my $album (@{ $request->getResult('albums_loop') || [] }) {
			$byId{$album->{id}} = $album;
		}
	}
	return [ grep { $_ } map { $byId{$_} } @list ];
}

# Title, artist, year, artwork and favourites URL of the listed albums, in list order (for the home row and the
# browse menu); with a Library View ID only the albums with a track in it.
sub albumDetails {
	my $libraryId = shift;
	cleanup();
	my @list = @{ inLibrary($prefs->get('list') || [], $libraryId) };
	return [] unless @list;

	my $dbh = Slim::Schema->dbh;
	my %byId;
	for (my $i = 0; $i < @list; $i += CHUNK) {
		my @chunk = @list[$i .. min($i + CHUNK, scalar @list) - 1];
		my $rows = $dbh->selectall_arrayref(q{
			SELECT albums.id, albums.title, albums.year, albums.artwork, albums.extid, contributors.name
			FROM albums
			LEFT JOIN contributors ON contributors.id = albums.contributor
			WHERE albums.id IN (} . join(',', map { '?' } @chunk) . ')', { Slice => {} }, @chunk);
		foreach my $row (@$rows) {
			utf8::decode($row->{title}) if defined $row->{title};
			utf8::decode($row->{name}) if defined $row->{name};
			$byId{$row->{id}} = $row;
		}
	}
	return [ grep { $_ } map { $byId{$_} } @list ];
}

sub _signalMaterial {
	if (Plugins::MaterialSkin::Plugin->can('signalHomeExtraUpdate')) {
		Plugins::MaterialSkin::Plugin::signalHomeExtraUpdate();
	}
}

1;
