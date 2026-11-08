package Plugins::RediscoverReleases::HomeExtras;

# The Material skin home row. Material asks for the row's items with "rediscoverhome items <index> <quantity>",
# which the OPML feed below answers (items from Items.pm). The feed is the whole list, so the row and its "more" view
# are the same items.

use strict;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::RediscoverReleases::Items;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant ICON => 'plugins/RediscoverReleases/html/images/icon_svg.png';

__PACKAGE__->initPlugin();

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed  => \&feed,
		tag   => 'rediscoverhome',
		extra => {
			title       => 'PLUGIN_REDISCOVER_RELEASES',
			icon        => ICON,
			needsPlayer => 1,   # the feed is an OPML CLI query, which LMS only runs for a player
		},
	);
}

# Material's own album rows (New Music, Recently Played) mark multi-disc albums and albums with works with a small icon
# on the cover. Material only does that for items of LMS's "albums" query, not for plugin items, so add the same
# icon here: its "overlay" item field shows any of its icons there.
sub handleExtra {
	my ($class, $client, $cb, $args) = @_;

	$class->SUPER::handleExtra($client, sub {
		my $results = shift;
		eval { _addOverlays($results) };
		logger('plugin.rediscoverreleases')->warn("Can't mark multi-disc albums: $@") if $@;
		$cb->($results);
	}, $args);
}

sub _addOverlays {
	my $results = shift;

	my $items = $results->{item_loop} || return;
	my %byAlbum;
	foreach my $item (@$items) {
		my $id = eval { $item->{actions}{go}{params}{album_id} };
		push @{$byAlbum{$id}}, $item if $id;
	}
	return unless %byAlbum;

	# Same rule as Material's albumGroupingType(): works (more than one group, in one block each) take precedence,
	# multi-disc only with LMS's "group discs" setting. Material's per-browser "use grouping" option can't be known
	# here; its default (on) is assumed.
	my $groupDiscs = preferences('server')->get('groupdiscs');
	my $request = Slim::Control::Request::executeRequest(undef,
		['albums', 0, scalar(keys %byAlbum), 'album_id:' . join(',', keys %byAlbum), 'library_id:-1', 'tags:q2']);
	foreach my $album (@{ $request->getResult('albums_loop') || [] }) {
		my $multiGroup = ($album->{group_count} || 0) > 1 && $album->{contiguous_groups};
		my $multiDisc  = $groupDiscs && ($album->{disccount} || 0) > 1;
		my $overlay = $multiGroup ? 'group-multi' : $multiDisc ? 'album-multi' : undef;
		next unless $overlay;
		$_->{overlay} = $overlay foreach @{ $byAlbum{$album->{id}} || [] };
	}
}

sub feed {
	my ($client, $cb, $args) = @_;

	# The whole list: the row is server wide, whatever the player's library
	$cb->({ items => Plugins::RediscoverReleases::Items::albumItems($client) });
}

1;
