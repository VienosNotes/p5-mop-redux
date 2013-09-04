package mop::util;

use v5.16;
use warnings;

our $VERSION   = '0.01';
our $AUTHORITY = 'cpan:STEVAN';

use Package::Stash;
use Hash::Util::FieldHash;
use Scalar::Util qw[ blessed ];

use Sub::Exporter -setup => {
    exports => [qw[
        find_meta
        has_meta
        find_or_create_meta
        apply_all_roles
        get_stash_for
        init_attribute_storage
        get_object_id
        fix_metaclass_compatibility
    ]]
};

sub find_meta { ${ get_stash_for( shift )->get_symbol('$METACLASS') || \undef } }
sub has_meta  {    get_stash_for( shift )->has_symbol('$METACLASS')  }

sub find_or_create_meta {
    my ($class) = @_;

    if (my $meta = find_meta($class)) {
        return $meta;
    }
    else {
        # creating a metaclass from an existing non-mop class
        my $stash = get_stash_for($class);

        my $name      = $stash->name;
        my $version   = $stash->get_symbol('$VERSION');
        my $authority = $stash->get_symbol('$AUTHORITY');
        my $isa       = $stash->get_symbol('@ISA');

        die "Multiple inheritance is not supported in mop classes"
            if @$isa > 1;

        my $new_meta = mop::class->new(
            name       => $name,
            version    => $version,
            authority  => $authority,
            superclass => $isa->[0],
        );

        for my $method ($stash->list_all_symbols('CODE')) {
            $new_meta->add_method(
                mop::method->new(
                    name => $method,
                    body => $stash->get_symbol('&' . $method),
                )
            );
        }

        # can't just use install_meta, because applying the mop mro to a
        # non-mop class will break things (SUPER, for instance)
        $stash->add_symbol('$METACLASS', \$new_meta);

        return $new_meta;
    }
}

sub apply_all_roles {
    my ($to, @roles) = @_;

    my $composite = mop::role->new(
        name => 'COMPOSITE::OF::[' . (join ', ' => map { $_->name } @roles) . ']'
    );

    foreach my $role ( @roles ) {
        $role->compose_into( $composite, $to );
    }

    $composite->compose_into( $to );
}

sub get_stash_for {
    state %STASHES;
    my $class = ref($_[0]) || $_[0];
    $STASHES{ $class } //= Package::Stash->new( $class )
}

sub get_object_id { Hash::Util::FieldHash::id( $_[0] ) }

sub register_object    { Hash::Util::FieldHash::register( $_[0] ) }
sub get_object_from_id { Hash::Util::FieldHash::id_2obj( $_[0] ) }

sub init_attribute_storage (\%) {
    &Hash::Util::FieldHash::fieldhash( $_[0] )
}

sub install_meta {
    my ($meta) = @_;

    die "Metaclasses must inherit from mop::class or mop::role"
        unless $meta->isa('mop::class') || $meta->isa('mop::role');

    my $stash = mop::util::get_stash_for($meta->name);
    $stash->add_symbol('$METACLASS', \$meta);
    $stash->add_symbol('$VERSION', \$meta->version);
    mro::set_mro($meta->name, 'mop');
}

sub uninstall_meta {
    my ($meta) = @_;

    die "Metaclasses must inherit from mop::class or mop::role"
        unless $meta->isa('mop::class') || $meta->isa('mop::role');

    my $stash = mop::util::get_stash_for($meta->name);
    $stash->remove_symbol('$METACLASS');
    $stash->remove_symbol('$VERSION');
    mro::set_mro($meta->name, 'dfs');
}

sub close_class {
    my ($class) = @_;

    my $new_meta = _get_class_for_closing($class);

    # XXX clear caches here if we end up adding any, and if we end up
    # implementing reopening of classes

    bless $class, $new_meta->name;
}

sub _get_class_for_closing {
    my ($class) = @_;

    my $class_meta = find_meta($class);

    my $closed_name = 'mop::closed::' . $class_meta->name;

    my $new_meta = find_meta($closed_name);
    return $new_meta if $new_meta;

    $new_meta = find_meta($class_meta)->new_instance(
        name       => $closed_name,
        version    => $class_meta->version,
        superclass => $class_meta->name,
        roles      => [],
    );
    install_meta($new_meta);

    my @mutable_methods = qw(
        add_attribute
        add_method
        add_required_method
        add_role
        add_submethod
        compose_into
        make_class_abstract
        remove_method
    );

    for my $method (@mutable_methods) {
        $new_meta->add_method(
            $new_meta->method_class->new(
                name => $method,
                body => sub { die "Can't call $method on a closed class" },
            )
        );
    }

    $new_meta->add_method(
        $new_meta->method_class->new(
            name => 'is_closed',
            body => sub { 1 },
        )
    );

    $new_meta->FINALIZE;

    my $stash = get_stash_for($class->name);
    for my $isa (@{ mop::mro::get_linear_isa($class->name) }) {
        if (has_meta($isa)) {
            for my $method (find_meta($isa)->methods) {
                $stash->add_symbol('&' . $method->name => $method->body);
            }
        }
    }

    return $new_meta;
}

sub fix_metaclass_compatibility {
    my ($meta, $super) = @_;

    my $meta_name  = blessed($meta);
    return $meta_name if !defined $super; # non-mop inheritance

    my $super_name = blessed($super);

    # immutability is on a per-class basis, it shouldn't be inherited.
    # otherwise, subclasses of closed classes won't be able to do things
    # like add attributes or methods to themselves
    $meta_name = mop::get_meta($meta_name)->superclass
        if $meta->isa('mop::class') && $meta->is_closed;
    $super_name = mop::get_meta($super_name)->superclass
        if $super->isa('mop::class') && $super->is_closed;

    return $meta_name  if $meta->isa($super_name);
    return $super_name if $super->isa($meta_name);

    my $rebased_meta_name = _rebase_metaclasses($meta_name, $super_name);
    return $rebased_meta_name if $rebased_meta_name;

    die "Can't fix metaclass compatibility between "
      . $meta->name . " (" . $meta_name . ") and "
      . $super->name . " (" . $super_name . ")";
}

sub _rebase_metaclasses {
    my ($meta_name, $super_name) = @_;

    my $common_base = _find_common_base($meta_name, $super_name);
    return unless $common_base;

    my @meta_isa = @{ mop::mro::get_linear_isa($meta_name) };
    pop @meta_isa until $meta_isa[-1] eq $common_base;
    pop @meta_isa;
    @meta_isa = reverse map { find_meta($_) } @meta_isa;

    my @super_isa = @{ mop::mro::get_linear_isa($super_name) };
    pop @super_isa until $super_isa[-1] eq $common_base;
    pop @super_isa;
    @super_isa = reverse map { find_meta($_) } @super_isa;

    # XXX i just haven't thought through exactly what this would mean - this
    # restriction may be able to be lifted in the future
    return if grep { $_->is_abstract } @meta_isa, @super_isa;

    my %super_method_overrides    = map { %{ $_->method_map    } } @super_isa;
    my %super_attribute_overrides = map { %{ $_->attribute_map } } @super_isa;

    my $current = $super_name;
    for my $class (@meta_isa) {
        return if grep {
            $super_method_overrides{$_->name}
        } $class->methods;

        return if grep {
            $super_attribute_overrides{$_->name}
        } $class->attributes;

        my $clone = $class->clone(
            name       => 'mop::class::rebased::' . $class->name,
            superclass => $current,
        );

        install_meta($clone);

        $current = $clone->name;
    }

    return $current;
}

sub _find_common_base {
    my ($meta_name, $super_name) = @_;

    my %meta_ancestors =
        map { $_ => 1 } @{ mop::mro::get_linear_isa($meta_name) };

    for my $super_ancestor (@{ mop::mro::get_linear_isa($super_name) }) {
        return $super_ancestor if $meta_ancestors{$super_ancestor};
    }

    return;
}

package mop::mro;

use strict;
use warnings;

{
    my %ISA_CACHE;

    sub clear_isa_cache {
        my ($class) = ref($_[0]) || $_[0];
        delete $ISA_CACHE{$class};
    }

    sub get_linear_isa {
        my $class = ref($_[0]) || $_[0];

        warn "======= got $class with cache: " . (join ", " => @{ $ISA_CACHE{$class} }) . "\n"
            if $class !~ /^mop::/ && $ISA_CACHE{$class};

        return $ISA_CACHE{$class} if $ISA_CACHE{$class};

        my @isa;
        my $current = $class;
        while (defined $current) {
            if (my $meta = mop::util::find_meta($current)) {
                push @isa, $current;
                $current = $meta->superclass;
            }
            else {
                push @isa, @{ mro::get_linear_isa($current) };
                last;
            }
        }

        Carp::cluck "======= setting cache for $class with : " . (join ", " => @isa) . "\n"
            if $class !~ /^mop::/;

        return $ISA_CACHE{$class} = \@isa;
    }

    # disable isa caching during global destruction, because things may have
    # started disappearing by that point
    END { %ISA_CACHE = () }
}

package mop::next;

use strict;
use warnings;

sub method {
    my ($invocant, @args) = @_;
    mop::internals::mro::call_method(
        $invocant,
        ${^CALLER}->[1],
        \@args,
        ${^CALLER}->[2]
    );
}

sub can {
    my ($invocant) = @_;
    my $method = mop::internals::mro::find_method(
        $invocant,
        ${^CALLER}->[1],
        ${^CALLER}->[2]
    );
    return unless $method;
    # NOTE:
    # we need to preserve any events
    # that have been attached to this
    # method.
    # - SL
    return sub { $method->execute( shift, [ @_ ] ) }
        if Scalar::Util::blessed($method) && $method->isa('mop::method');
    return $method;
}

1;

__END__

=pod

=head1 NAME

mop::util - collection of utilities for the mop

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

