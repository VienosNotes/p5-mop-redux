package mop::internals::mro;

use v5.16;
use warnings;

use mop::util qw[
    has_meta
    find_meta
    get_stash_for
];

use B;
use Devel::GlobalDestruction;
use MRO::Define;
use Scalar::Util    qw[ blessed ];
use Variable::Magic qw[ wizard cast dispell ];

BEGIN {
    MRO::Define::register_mro(
        'mop',
        sub {
            my $pkg = B::svref_2object($_[0])->NAME;
            [ 'mop::internals::mro::' . $pkg ]
        }
    )
}

{
    my %METHOD_CACHE;

    sub clear_method_cache_for {
        my ($invocant) = @_;
        delete $METHOD_CACHE{method_cache_for($invocant)};
    }

    sub method_cache_lookup {
        my ($invocant, $method_name, $super_of) = @_;
        my $pkg = method_cache_for($invocant);
        my $super = $super_of ? $super_of->name : '';
        return $METHOD_CACHE{$pkg}{$method_name}{$super};
    }

    sub add_to_method_cache {
        my ($invocant, $method_name, $super_of, $method) = @_;
        my $pkg = method_cache_for($invocant);
        my $super = $super_of ? $super_of->name : '';
        $METHOD_CACHE{$pkg}{$method_name}{$super} = $method;
    }

    sub method_cache_for {
        my ($invocant) = @_;
        return blessed($invocant) || $invocant;
    }

    # disable method caching during global destruction, because things may have
    # started disappearing by that point
    END { %METHOD_CACHE = () }
}

sub find_method {
    my ($invocant, $method_name, $super_of) = @_;
    if (my $method = method_cache_lookup($invocant, $method_name, $super_of)) {
        return $method;
    }
    return add_to_method_cache(
        $invocant, $method_name, $super_of,
        _find_method($invocant, $method_name, $super_of)
    );
}

sub _find_method {
    my ($invocant, $method_name, $super_of) = @_;

    my @mro = @{ mop::mro::get_linear_isa( $invocant ) };

    # NOTE:
    # this is ugly, needs work
    # - SL
    if ( defined $super_of ) {
        #warn "got super-of";
        #warn "MRO: " . $mro[0];
        #warn "SUPEROF: " . $super_of->name;
        while ( $mro[0] && $mro[0] ne $super_of->name ) {
            #warn "no match, shifting until we find it";
            shift( @mro );
        }
        #warn "got it, shifting";
        shift( @mro );
    }

    foreach my $class ( @mro ) {
        if (my $meta = find_meta($class)) {
            return $meta->get_method( $method_name )
                if $meta->has_method( $method_name );
        } else {
            my $stash = get_stash_for( $class );
            return $stash->get_symbol( '&' . $method_name )
                if $stash->has_symbol( '&' . $method_name );
        }
    }

    if (my $universally = UNIVERSAL->can($method_name)) {
        if (my $method = find_meta('mop::object')->get_method($method_name)) {
            # we're doing method lookup on a mop class which doesn't inherit
            # from mop::object (otherwise this would have been found above). we
            # need to use the mop::object version of the appropriate UNIVERSAL
            # methods, because the methods in UNIVERSAL won't necessarily do
            # the right thing for mop objects.
            return $method;
        }
        else {
            # a method which was added to UNIVERSAL manually, or a method whose
            # implementation in UNIVERSAL also works for mop objects
            return $universally;
        }
    }

    return;
}

sub find_submethod {
    my ($invocant, $method_name) = @_;

    if (my $meta = find_meta($invocant)) {
        return $meta->get_submethod( $method_name );
    }

    return;
}

sub call_method {
    my ($invocant, $method_name, $args, $super_of) = @_;

    # XXX
    # for some reason, we are getting a lot
    # of "method not found" type errors in
    # 5.18 during local scope destruction
    # and there doesn't seem to be any
    # sensible way to fix this. Hence, this
    # horrid fucking kludge.
    # - SL
    local $SIG{'__WARN__'} = sub {
        warn $_[0] unless $_[0] =~ /\(in cleanup\)/
    };

    my $method = find_submethod( $invocant, $method_name );
    $method    = find_method( $invocant, $method_name, $super_of )
        unless defined $method;

    die "Could not find $method_name in " . $invocant
        unless defined $method;

    # need to localize these two
    # globals here so that they
    # will be available to methods
    # added with "add_method" as
    # well as
    local ${^SELF}  = $invocant;
    local ${^CLASS} = find_meta($invocant);

    if ( blessed $method && $method->isa('mop::method') ) {
        return $method->execute( $invocant, $args );
    } elsif ( ref $method eq 'CODE' ) {
        return $method->($invocant, @$args);
    } else {
        die "Unrecognized method type: $method";
    }
}

# Here is where things get a little ugly,
# we need to wrap the stash in magic so
# that we can capture calls to it
{
    my $method_called;
    my $is_fetched = 0;

    sub invoke_method {
        my ($caller, @args) = @_;

        # NOTE: this warning can be used to
        # diagnose the double-invoke/no-fetch bug
        #warn "++++ $method_called called without wizard->fetch" if not $is_fetched;

        # FIXME:
        # So for some really odd reason I cannot
        # seem to diagnose, every once in a while
        # invoke_method will be called, but the
        # wizard->fetch magic below will *not*
        # be called.
        #
        # To make it even more confusing, the $caller
        # value is retained, but the @args values
        # are not (they show up as undef).
        #
        # To make it even /more/ confusing,
        # if I was to detect the situation (which
        # is easy to do when you find a reproduceable
        # case, simply by checking for undef args
        # when you know for sure they should be
        # defined), and then die in response to
        # the situation, the die gets swallowed
        # up and everything just works fine.
        #
        # Bug in Perl? Is putting magic on the stash
        # just too damn funky? I have no idea, but
        # this code below will detect the situation
        # (the lack of wizard->fetch/invoke_method
        # pair) and stop it. I leave the DESTROY
        # exception in place because that seemed to
        # be happening on a semi-legit basis.
        #
        # - SL
        if (!$is_fetched && $method_called ne 'DESTROY') {
            return;
        }
        $is_fetched = 0;

        # NOTE: this warning can be used to
        # diagnose the double-invoke/no-fetch bug
        #warn join ", " => "invoke_method: ", $caller, $method_called, @args;

        call_method($caller, $method_called, \@args);
    }

    my $wiz = wizard(
        data  => sub { [ \$method_called, \$is_fetched, $_[1] ] },
        fetch => sub {
            return if $_[2] =~ /::$/;     # this is a substash lookup
            return if $_[2] =~ /^\(/      # no overloaded methods
                   || $_[2] eq 'AUTOLOAD' # no AUTOLOAD (never!!)
                   || $_[2] eq 'import'   # classes don't import
                   || $_[2] eq 'unimport';  # and they certainly don't export
            return if $_[2] eq 'DESTROY' && in_global_destruction;

            # NOTE: this warning can be used to
            # diagnose the double-invoke/no-fetch bug
            #warn join ", " => "wizard->fetch: ", ${$_[1]->[1]}, ${$_[1]->[0]}, $_[2];

            ${ $_[1]->[1] } = 1;
            ${ $_[1]->[0] } = $_[2];
            $_[2] = 'invoke_method';
            # mro::method_changed_in('UNIVERSAL');

            # NOTE: this warning can be used to
            # diagnose the double-invoke/no-fetch bug
            #Carp::cluck("HI");

            ();
        }
    );

    sub install_mro {
        my ($pkg) = @_;
        my $stash = get_stash_for('mop::internals::mro::' . $pkg);
        cast %{ $stash->namespace }, $wiz, $pkg;
        $stash->add_symbol('&invoke_method' => \&invoke_method);
    }

    sub uninstall_mro {
        my ($pkg) = @_;
        my $stash = get_stash_for('mop::internals::mro::' . $pkg);
        dispell %{ $stash->namespace }, $wiz;
        $stash->remove_symbol('&invoke_method');
    }
}

1;

__END__

=pod

=head1 NAME

mop::internal::mro

=head1 DESCRIPTION

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little <stevan@iinteractive.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Infinity Interactive.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut






