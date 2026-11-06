#!/usr/bin/perl
# Tests of the list building and cleanup (RediscoverReleases/List.pm) against a copy of a real LMS library.
#
# Runs outside LMS with small stand-ins for the LMS modules List.pm uses; the database is real. Needs DBI and
# DBD::SQLite, e.g. those bundled with LMS (see t/run.sh, which runs it in the LMS Docker image):
#   perl t/list.t <copy of cache/library.db> <copy of prefs/persist.db>
# The copies are modified (play data) - never point it at a live server's files.

use strict;
use warnings;

use FindBin;
use Test::More;
use DBI;

my ($libraryDb, $persistDb) = @ARGV;
plan skip_all => 'usage: list.t <library.db copy> <persist.db copy>' unless $libraryDb && $persistDb && -f $libraryDb && -f $persistDb;

# ---- stand-ins for the LMS modules ----
BEGIN {
	package main;
	use constant INFOLOG => 0;
	use constant DEBUGLOG => 0;

	$INC{$_} = 1 for qw(Slim/Utils/Log.pm Slim/Utils/Prefs.pm Slim/Utils/Timers.pm Slim/Music/Import.pm Slim/Schema.pm
		Slim/Music/VirtualLibraries.pm);

	package TestLog;
	sub new { bless {}, shift }
	sub AUTOLOAD { return 0 }
	sub error { shift; push @main::errors, join('', @_) }
	sub warn { shift; push @main::warnings, join('', @_) }

	package Slim::Utils::Log;
	sub import { no strict 'refs'; *{caller() . '::logger'} = sub { TestLog->new } }

	package TestPrefs;
	our %values;
	sub new { bless {}, shift }
	sub get { $values{$_[1]} }
	sub set { $values{$_[1]} = $_[2] }

	package Slim::Utils::Prefs;
	sub import { no strict 'refs'; *{caller() . '::preferences'} = sub { TestPrefs->new } }

	package Slim::Utils::Timers;
	our @timers;
	sub setTimer { push @timers, [@_] }
	sub killTimers { }

	package Slim::Music::Import;
	sub stillScanning { 0 }

	package Slim::Schema;
	our $dbh;
	sub dbh { $dbh }

	package Slim::Music::VirtualLibraries;
	sub getLibraries { {} }   # List.pm falls back to the library_track table
}

$Slim::Schema::dbh = DBI->connect("dbi:SQLite:dbname=$libraryDb", '', '', { RaiseError => 1, AutoCommit => 1 });
$Slim::Schema::dbh->do("ATTACH DATABASE '$persistDb' AS persistentdb");

use lib "$FindBin::Bin/../RediscoverReleases/..";
{
	# List.pm is Plugins::RediscoverReleases::List
	my $dir = "$FindBin::Bin/../RediscoverReleases";
	no warnings 'once';
	$INC{'Plugins/RediscoverReleases/List.pm'} = "$dir/List.pm";
	do "$dir/List.pm" or die "List.pm: " . ($@ || $!);
}

my $dbh = $Slim::Schema::dbh;
my %defaults = (count => 250, months => 12, includeUnplayed => 1, minPlayedPct => 20, genres => [], partialAs => 'unplayed',
	rebuildHours => 24, list => [], builtAt => 0, version => 0, libraryId => '', libraryMatch => 'any', minRating => 0,
	includeUnrated => 1, dstmAlbums => 1);

sub setPrefs { %TestPrefs::values = (%defaults, @_) }

# album ID => [tracks, played tracks, oldest last play of the played tracks]
sub stats {
	return { map { $_->[0] => [ @$_[1..3] ] } @{ Plugins::RediscoverReleases::List::albumStats() } };
}

sub build {
	setPrefs(@_);
	ok(Plugins::RediscoverReleases::List::rebuild('test'), 'built');
	return $TestPrefs::values{list};
}

sub monthsAgo { Plugins::RediscoverReleases::List::_monthsAgo(shift) }

my $all = do { setPrefs(); stats() };
my $albums = scalar keys %$all;
ok($albums > 100, "library has $albums albums");

my @played = grep { $all->{$_}->[1] == $all->{$_}->[0] } keys %$all;
my @partial = grep { $all->{$_}->[1] && $all->{$_}->[1] < $all->{$_}->[0] } keys %$all;
diag(sprintf('%d albums: %d fully played, %d partially played', $albums, scalar @played, scalar @partial));

subtest 'defaults' => sub {
	my $list = build();
	is(scalar @$list, 250, '250 albums');
	my %seen; $seen{$_}++ for @$list;
	is(scalar keys %seen, 250, 'no duplicates');
	my $playedCount = grep { $all->{$_}->[1] == $all->{$_}->[0] } @$list;
	cmp_ok($playedCount, '>=', 50, "at least 20% played ($playedCount)");
	is($TestPrefs::values{version}, 1, 'version bumped');
	ok($TestPrefs::values{builtAt} > time() - 5, 'build time set');
};

subtest 'shuffled each build' => sub {
	my $a = join(',', @{ build() });
	my $b = join(',', @{ build() });
	isnt($a, $b, 'two builds differ');
};

subtest 'without unplayed albums' => sub {
	my $list = build(includeUnplayed => 0, count => 100);
	is(scalar @$list, 100, '100 albums');
	is(scalar(grep { $all->{$_}->[1] < $all->{$_}->[0] } @$list), 0, 'all fully played (partial counts as unplayed)');
};

subtest 'partially played as played' => sub {
	my $list = build(includeUnplayed => 0, partialAs => 'played', count => 1000);
	my $partialIn = grep { $all->{$_}->[1] && $all->{$_}->[1] < $all->{$_}->[0] } @$list;
	is(scalar @$list, scalar(@played) + scalar(@partial) > 1000 ? 1000 : scalar(@played) + scalar(@partial), 'all played and partially played albums');
	ok($partialIn > 0, "partially played albums included ($partialIn)");
	is(scalar(grep { !$all->{$_}->[1] } @$list), 0, 'no unplayed album');
};

subtest '100% played' => sub {
	my $list = build(minPlayedPct => 100, count => 50);
	is(scalar(grep { $all->{$_}->[1] < $all->{$_}->[0] } @$list), 0, 'all 50 played');
};

subtest '0% played' => sub {
	my $list = build(minPlayedPct => 0, count => 1000);
	is(scalar @$list, 1000, '1000 albums');
};

subtest 'not played for M months comes first' => sub {
	# Find a month count that splits the played albums, so both "old" and "recent" exist.
	my @lastPlays = sort { $a <=> $b } map { $all->{$_}->[2] } @played;
	plan skip_all => 'no played albums' unless @lastPlays;
	my $median = $lastPlays[int(@lastPlays / 2)];
	my $months = 1;
	$months++ while $months < 99 && monthsAgo($months) > $median;
	$months-- if $months > 1;
	my $cutoff = monthsAgo($months);
	my @old = grep { $all->{$_}->[2] < $cutoff } @played;
	plan skip_all => "no albums older than $months months" unless @old;
	diag(sprintf('%d months: %d of %d played albums are older', $months, scalar @old, scalar @played));

	my $want = @old < 30 ? scalar @old : 30;
	my $list = build(includeUnplayed => 0, months => $months, count => $want);
	is(scalar(grep { $all->{$_}->[2] >= $cutoff } @$list), 0, "only albums not played for $months months");

	$list = build(includeUnplayed => 0, months => $months, count => scalar(@old) + 5);
	my @recent = grep { $all->{$_}->[2] >= $cutoff } @$list;
	is(scalar @recent, 5, 'topped up with 5 recently played albums');
	my @recentSorted = sort { $all->{$a}->[2] <=> $all->{$b}->[2] } grep { $all->{$_}->[2] >= $cutoff } @played;
	is_deeply([ sort @recent ], [ sort @recentSorted[0..4] ], 'the 5 least recently played');
};

subtest 'genres' => sub {
	my $genres = Plugins::RediscoverReleases::List::genres();
	ok(@$genres > 0, scalar(@$genres) . ' genres');
	my ($genre) = sort { $b->[1] <=> $a->[1] } @$genres;
	my $list = build(genres => [ $genre->[0] ], count => 1000);
	is(scalar @$list, $genre->[1] > 1000 ? 1000 : $genre->[1], "all $genre->[1] albums of '$genre->[0]'");
	my $outside = $dbh->selectcol_arrayref('SELECT COUNT(*) FROM albums WHERE id IN (' . join(',', @$list) . ') AND id NOT IN '
		. '(SELECT tracks.album FROM tracks JOIN genre_track ON genre_track.track = tracks.id JOIN genres ON genres.id = genre_track.genre WHERE genres.name = ?)',
		undef, $genre->[0])->[0];
	is($outside, 0, 'none outside the genre');
};

subtest 'genres excluded' => sub {
	my ($genre) = sort { $b->[1] <=> $a->[1] } @{ Plugins::RediscoverReleases::List::genres() };
	my $withGenre = $dbh->selectcol_arrayref('SELECT DISTINCT tracks.album FROM tracks JOIN genre_track ON genre_track.track = tracks.id'
		. ' JOIN genres ON genres.id = genre_track.genre WHERE genres.name = ? AND tracks.audio = 1', undef, $genre->[0]);
	my %withGenre = map { $_ => 1 } @$withGenre;
	setPrefs(genres => [ $genre->[0] ], genreFilter => 'exclude');
	my $stats = stats();
	is(scalar keys %$stats, $albums - scalar(grep { $all->{$_} } @$withGenre), "all albums except the $genre->[1] of '$genre->[0]'");
	is(scalar(grep { $withGenre{$_} } keys %$stats), 0, 'none with a track of the genre');
	my $list = build(genres => [ $genre->[0] ], genreFilter => 'exclude', count => 1000);
	is(scalar(grep { $withGenre{$_} } @$list), 0, 'list has none of them');
	setPrefs(genres => [ $genre->[0] ], genreFilter => 'all');
	is(scalar keys %{ stats() }, $albums, "'all' ignores the selection");
	setPrefs(genres => [ $genre->[0] ]);   # saved before 1.1: no genreFilter
	is(scalar keys %{ stats() }, $genre->[1], 'without genreFilter a selection includes');
};

subtest 'Library View' => sub {
	my $views = $dbh->selectall_arrayref('SELECT library, COUNT(*) FROM library_track GROUP BY library ORDER BY COUNT(*)');
	plan skip_all => 'no Library Views' unless @$views;
	# a view with some albums only partly in it
	my ($view) = grep {
		$dbh->selectrow_array('SELECT COUNT(DISTINCT t.album) FROM tracks t JOIN library_track lt ON lt.track = t.id AND lt.library = ?'
			. ' WHERE t.album IN (SELECT t2.album FROM tracks t2 LEFT JOIN library_track l2 ON l2.track = t2.id AND l2.library = ?'
			. ' WHERE t2.audio = 1 AND l2.track IS NULL)', undef, $_->[0], $_->[0])
	} @$views;
	plan skip_all => 'no view with partly included albums' unless $view;
	my $id = $view->[0];
	my $any = $dbh->selectcol_arrayref('SELECT DISTINCT t.album FROM tracks t JOIN library_track lt ON lt.track = t.id WHERE lt.library = ? AND t.audio = 1', undef, $id);
	my $partly = $dbh->selectcol_arrayref('SELECT DISTINCT t.album FROM tracks t LEFT JOIN library_track lt ON lt.track = t.id AND lt.library = ?'
		. ' WHERE t.audio = 1 AND lt.track IS NULL', undef, $id);
	my %partly = map { $_ => 1 } @$partly;
	my @all = grep { !$partly{$_} } @$any;
	diag(sprintf('view %s: %d albums with any track, %d with all tracks', $id, scalar @$any, scalar @all));

	setPrefs(libraryId => $id);
	is_deeply([ sort { $a <=> $b } keys %{ stats() } ], [ sort { $a <=> $b } @$any ], 'any: albums with a track in the view');
	setPrefs(libraryId => $id, libraryMatch => 'all');
	is_deeply([ sort { $a <=> $b } keys %{ stats() } ], [ sort { $a <=> $b } @all ], 'all: albums with all tracks in the view');
	my $album = (grep { $partly{$_} } @$any)[0];
	is(stats()->{$album}, undef, "album $album, partly in the view, left out with 'all'");

	setPrefs(libraryId => 'nosuchview');
	is(scalar keys %{ stats() }, $albums, 'a view that is gone is ignored');
	ok(scalar(grep { /nosuchview/ } @main::warnings), 'and logged');
	@main::warnings = ();

	setPrefs(list => [ @$any[0..2], @$partly[0..2] ]);
	my %partlyOrNot = map { $_ => 1 } @$any;
	is(scalar @{ Plugins::RediscoverReleases::List::inLibrary($TestPrefs::values{list}, $id) },
		scalar(grep { $partlyOrNot{$_} } @{ $TestPrefs::values{list} }), 'inLibrary keeps the albums with a track in the view');
	is(scalar @{ Plugins::RediscoverReleases::List::inLibrary($TestPrefs::values{list}, '') }, 6, 'no view: all');
};

subtest 'minimum rating' => sub {
	setPrefs();
	my $rows = { map { $_->[0] => $_ } @{ Plugins::RediscoverReleases::List::albumStats() } };
	my @rated = grep { $rows->{$_}->[4] } keys %$rows;
	plan skip_all => 'no rated tracks' unless @rated;
	# The average counts rated tracks only
	my ($mixed) = grep { $rows->{$_}->[4] < $rows->{$_}->[1] } @rated;
	if ($mixed) {
		my $avg = $dbh->selectrow_array('SELECT AVG(tp.rating) FROM tracks t JOIN tracks_persistent tp ON tp.urlmd5 = t.urlmd5'
			. ' WHERE t.album = ? AND t.audio = 1 AND tp.rating > 0', undef, $mixed);
		is($rows->{$mixed}->[5], $avg, "album $mixed: average of its $rows->{$mixed}->[4] rated of $rows->{$mixed}->[1] tracks");
	}
	my $min = 80;
	my @good = grep { $rows->{$_}->[5] >= $min } @rated;
	diag(sprintf('%d albums with rated tracks, %d averaging 4 stars or more', scalar @rated, scalar @good));

	my $list = build(minRating => $min, includeUnrated => 0, count => 1000, minPlayedPct => 0);
	is_deeply([ sort { $a <=> $b } @$list ], [ sort { $a <=> $b } @good[0 .. (@good > 1000 ? 999 : $#good)] ], 'only albums averaging 4 stars');
	is($TestPrefs::values{stats}->{belowRating}, $albums - @good, 'the others counted as left out');

	$list = build(minRating => $min, includeUnrated => 1, count => 1000, minPlayedPct => 0);
	my %low = map { $_ => 1 } grep { $rows->{$_}->[5] < $min } @rated;
	is(scalar(grep { $low{$_} } @$list), 0, 'with unrated: still none below 4 stars');
	ok(scalar(grep { !$rows->{$_}->[4] } @$list) > 0, 'but unrated albums');
};

subtest "Don't Stop The Music" => sub {
	build(count => 20);
	my @list = @{ $TestPrefs::values{list} };
	my $urls = Plugins::RediscoverReleases::List::mixTracks(2, {});
	my $albumsOf = sub {
		my %a;
		foreach my $url (@{ shift() }) {
			$a{ $dbh->selectrow_array('SELECT album FROM tracks WHERE url = ?', undef, $url) } = 1;
		}
		return [ keys %a ];
	};
	my $picked = $albumsOf->($urls);
	is(scalar @$picked, 2, 'two albums');
	my %listed = map { $_ => 1 } @list;
	is(scalar(grep { $listed{$_} } @$picked), 2, 'from the list');
	my $expected = $dbh->selectrow_array('SELECT COUNT(*) FROM tracks WHERE audio = 1 AND album IN (' . join(',', @$picked) . ')');
	is(scalar @$urls, $expected, 'all their tracks');

	my $album = $picked->[0];
	my $order = $dbh->selectcol_arrayref('SELECT url FROM tracks WHERE album = ? AND audio = 1 ORDER BY COALESCE(disc,0), COALESCE(tracknum,0), titlesort', undef, $album);
	my @inMix = grep { my $u = $_; grep { $_ eq $u } @$order } @$urls;
	is_deeply(\@inMix, $order, 'in disc and track order');

	my %skip = map { $_ => 1 } @list[0..17];
	my $rest = $albumsOf->(Plugins::RediscoverReleases::List::mixTracks(5, \%skip));
	is_deeply([ sort @$rest ], [ sort @list[18, 19] ], 'albums in the queue are skipped');
	is(scalar @{ Plugins::RediscoverReleases::List::mixTracks(3, { map { $_ => 1 } @list }) }, 0, 'nothing left: no tracks');
};

subtest 'played in full is removed' => sub {
	my $list = build(count => 100);
	my ($full, $half) = grep { $all->{$_}->[0] >= 2 } @$list;
	my $builtAt = $TestPrefs::values{builtAt};
	my $tracks = sub {
		$dbh->selectcol_arrayref('SELECT urlmd5 FROM tracks WHERE album = ? AND audio = 1', undef, shift);
	};
	my $play = sub {
		my $urlmd5 = shift;
		my $n = $dbh->do('UPDATE tracks_persistent SET playcount = COALESCE(playcount, 0) + 1, lastplayed = ? WHERE urlmd5 = ?', undef, $builtAt + 10, $urlmd5);
		$dbh->do('INSERT INTO tracks_persistent (urlmd5, url, playcount, lastplayed, added) SELECT urlmd5, url, 1, ?, ? FROM tracks WHERE urlmd5 = ?',
			undef, $builtAt + 10, $builtAt, $urlmd5) if $n == 0;
	};
	$play->($_) for @{ $tracks->($full) };
	my @halfTracks = @{ $tracks->($half) };
	$play->($_) for @halfTracks[0 .. $#halfTracks - 1];

	is(Plugins::RediscoverReleases::List::cleanup(), 0, 'nothing marked: nothing checked');
	Plugins::RediscoverReleases::List::markPlayed($_) for ($full, $half, 999999999);
	ok(scalar(grep { $_->[2] == \&Plugins::RediscoverReleases::List::_cleanupTimer } @Slim::Utils::Timers::timers), 'cleanup timer set');
	is(Plugins::RediscoverReleases::List::cleanup(), 1, 'one album removed');
	my %now = map { $_ => 1 } @{ $TestPrefs::values{list} };
	ok(!$now{$full}, 'album played in full is gone');
	ok($now{$half}, 'album with a track left is kept');
	is(scalar keys %now, 99, '99 left');
	is($TestPrefs::values{version}, 2, 'version bumped');
	is(Plugins::RediscoverReleases::List::cleanup(), 0, 'marks cleared');
};

subtest 'rescan' => sub {
	build(count => 100);
	my @list = @{ $TestPrefs::values{list} };
	$TestPrefs::values{list} = [ @list[0..69], 900000001 .. 900000030 ];
	Plugins::RediscoverReleases::List::afterRescan();
	is(scalar @{ $TestPrefs::values{list} }, 70, 'missing albums dropped');
	$TestPrefs::values{list} = [ @list[0..9], 900000001 .. 900000030 ];
	Plugins::RediscoverReleases::List::afterRescan();
	is(scalar @{ $TestPrefs::values{list} }, 100, 'mostly gone: rebuilt');
};

subtest 'text is decoded' => sub {
	my $row = $dbh->selectrow_arrayref(q{SELECT id, title FROM albums WHERE title GLOB '*[^ -~]*' LIMIT 1});
	my ($id, $raw) = $row ? @$row : ();
	plan skip_all => 'no album title with non-ASCII characters' unless $id;
	setPrefs(list => [$id]);
	my ($album) = @{ Plugins::RediscoverReleases::List::albumDetails() };
	my $expected = $raw; utf8::decode($expected);
	is($album->{title}, $expected, 'album title decoded once');
	ok(utf8::is_utf8($album->{title}), 'character string');

	my ($genre) = grep { $_->[0] =~ /[^\x00-\x7f]/ } @{ Plugins::RediscoverReleases::List::genres() };
	if ($genre) {
		setPrefs(genres => [ $genre->[0] ]);
		is(scalar @{ Plugins::RediscoverReleases::List::albumStats() }, $genre->[1], "filter by non-ASCII genre '$genre->[0]'");
	}
};

is_deeply(\@main::errors, [], 'no errors logged');
done_testing();
