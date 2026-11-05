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

	$INC{$_} = 1 for qw(Slim/Utils/Log.pm Slim/Utils/Prefs.pm Slim/Utils/Timers.pm Slim/Music/Import.pm Slim/Schema.pm);

	package TestLog;
	sub new { bless {}, shift }
	sub AUTOLOAD { return 0 }
	sub error { shift; push @main::errors, join('', @_) }

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
	rebuildHours => 24, list => [], builtAt => 0, version => 0);

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
