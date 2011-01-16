package Net::Appliance::Session::ActionSet;

use Moose;
use Net::Appliance::Session::Action;
with 'Net::Appliance::Session::Role::Iterator';

has '_sequence' => (
    is => 'rw',
    isa  => 'ArrayRef[Net::Appliance::Session::Action]',
    auto_deref => 1,
    required => 1,
);

sub BUILDARGS {
    my ($class, @rest) = @_;
    # accept single hash ref or naked hash
    my $params = (ref $rest[0] eq ref {} and scalar @rest == 1 ? $rest[0] : {@rest});

    if (exists $params->{actions} and ref $params->{actions} eq ref []) {
        foreach my $a (@{$params->{actions}}) {
            if (ref $a eq 'Net::Appliance::Session::ActionSet') {
                push @{$params->{_sequence}}, $a->_sequence;
                next;
            }

            if (ref $a eq 'Net::Appliance::Session::Action') {
                push @{$params->{_sequence}}, $a;
                next;
            }

            if (ref $a eq ref {}) {
                push @{$params->{_sequence}},
                    Net::Appliance::Session::Action->new($a);
                next;
            }

            confess "don't know what to do with a: '$a'\n";
        }
        delete $params->{actions};
    }

    return $params;
}

sub clone {
    my $self = shift;
    return Net::Appliance::Session::ActionSet->new({
        actions => [ map { $_->clone } $self->_sequence ],
        _callbacks => $self->_callbacks,
    });
}

# store params to the set, used when send is passed via sprintf
sub apply_params {
    my ($self, @params) = @_;

    $self->reset;
    while ($self->has_next) {
        my $next = $self->next;
        $next->params($params[$self->idx] || []);
    }

    return $self; # required
}

has _callbacks => (
    is => 'rw',
    isa => 'ArrayRef[CodeRef]',
    required => 0,
    default => sub { [] },
);

sub register_callback {
    my $self = shift;
    $self->_callbacks([ @{$self->_callbacks}, shift ]);
}

sub execute {
    my $self = shift;
    $self->reset;
    while ($self->has_next) {
        $_->($self->next) for @{$self->_callbacks};
    }
}

# pad out the Actions with match Actions if needed between send pairs
before 'execute' => sub {
    my ($self, $current_match) = @_;
    confess "execute requires the current match action as a parameter\n"
        unless defined $current_match
            and ref $current_match eq 'Net::Appliance::Session::Action'
            and $current_match->type eq 'match';

    $self->reset;
    while ($self->has_next) {
        my $this = $self->next;
        my $next = $self->peek or last; # careful...
        next unless $this->type eq 'send' and $next->type eq 'send';

        $self->insert_at($self->idx + 1, $current_match);
    }
};

# carry-forward a continuation beacause it's the match
# which really does the heavy lifting there
before 'execute' => sub {
    my $self = shift;

    $self->reset;
    while ($self->has_next) {
        my $this = $self->next;
        my $next = $self->peek or last; # careful...
        next unless $this->type eq 'send'
            and defined $this->continuation
            and $next->type eq 'match';

        $next->continuation( $this->continuation );
    }
};

# marshall the responses so as to move data from match to send
after 'execute' => sub {
    my $self = shift;

    $self->reset;
    while ($self->has_next) {
        my $send = $self->next;
        my $match = $self->peek or last; # careful...
        next unless $match->type eq 'match';

        my $response = $match->response; # need an lvalue
        my $cmd = $send->value;
        $response =~ s/^$cmd\s+//;

        if ($response =~ s/(\s+)(\S+)\s*$/$1/) {
            $match->response($2);
            $send->response($response);
        }
    }
};

1;
