create or replace function sv_cmp(IN sep text, IN cigar1 text, IN cigar2 text, OUT mask text)
strict immutable language plperl as
$$
    # given two sep-separated strings, a mask with ^^^ highlighting disagreement

    use strict;
    use warnings;

    my ($sep,$c1,$c2) = @_;

    my @e1 = split($sep,$c1);
    my @e2 = split($sep,$c2);

    my $min = $#e1 < $#e2 ? $#e1 : $#e2;
    my @rv = map {$e1[$_] eq $e2[$_] ? ' ' x length($e1[$_]) : '^' x length($e1[$_])} 0..$min;

    if ($#e1 > $min) {
        push(@rv,'+e1',@e1[$min+1,$#e1]);
    } elsif ($#e2 > $min) {
        push(@rv,'+e2',@e2[$min+1,$#e2]);
    }
    
    return join($sep,@rv);
$$;


create or replace function u0_to_u1_cigar(c text) returns text
strict immutable language plperl as
$$
my ($c) = @_;
$c =~ tr/DIM/di=/;
$c =~ tr/di/ID/;
return $c;
$$;


create or replace function u0_to_u1_status(s text) returns text
strict immutable language plperl as
$$
my ($_) = @_;
s/dI/Di/ or s/Di/dI/;
return $_;
$$;


create or replace function aln_status(IN tx_se_i text, IN alt_se_i text, IN cigars text, OUT status text)
strict immutable language plperl as
$$
    # returns NLxdi-string

    use strict;
    use warnings;

    my ($tx_se_i,$alt_se_i,$cigars) = @_;
    my (@tx_se_i) = map( { [split(',',$_)] } split(';',$tx_se_i) );
    my (@tx_lens) = map( { $_->[1]-$_->[0] } @tx_se_i );

    my (@alt_se_i) = map( { [split(',',$_)] } split(';',$alt_se_i) );
    my (@alt_lens) = map( { $_->[1]-$_->[0] } @alt_se_i );

    my $N = $#tx_se_i == $#alt_se_i ? 'N' : 'n';
    my $L = join(';',@tx_lens) eq join(';',@alt_lens) ? 'L' : 'l';
    my $X = $cigars =~ 'X' ? 'X' : 'x';
    my $D = $cigars =~ 'D' ? 'D' : 'd';
    my $I = $cigars =~ 'I' ? 'I' : 'i';
    
    my $rv = "$N$L$X$D$I";
    return $rv;
$$;


create or replace function cigar_stats(
       IN cigars text,
       OUT collapsed_cigar text,
       OUT l1 int,
       OUT l2 int,
       OUT n_ex int,
       OUT n_ops int,
       OUT n_e int,
       OUT n_x int,
       OUT n_d int,
       OUT n_i int,
       OUT t_e int,
       OUT t_x int,
       OUT t_d int,
       OUT t_i int,
	   OUT stats text
       )
strict immutable language plperl as
$$
    use strict;
    use warnings;

    my ($cigars) = @_;
    my (%rv) = map {$_=>0} qw(l1 l2 n_ex n_ops   
                              n_e n_x n_d n_i
                              t_e t_x t_d t_i);

    $rv{'n_ex'} = $cigars =~ tr/;/;/ + 1;

    my $cigar = $cigars;
    $cigar =~ s/;//g;
    while ($cigar =~ s/(\d+)(\D)(\d+)\2/sprintf("%d%s",$1+$3,$2)/eg) {};
    $rv{'collapsed_cigar'} = $cigar;

    my @elems = $cigar =~ m/\d+\D/g;
    $rv{'n_ops'} = $#elems + 1;

    foreach my $e (@elems) {
        my ($n,$op) = $e =~ m/(\d+)(\D)/;
        $op = $op eq '=' ? 'e' : lc($op);
        $rv{"n_$op"} += 1;
        $rv{"t_$op"} += $n;
    }
    
    $rv{'l1'} = $rv{'t_e'} + $rv{'t_x'} + $rv{'t_d'};
    $rv{'l2'} = $rv{'t_e'} + $rv{'t_x'} + $rv{'t_i'};
    $rv{'stats'} = join('; ', map {sprintf("%s:%s",$_,$rv{$_})} qw(l1 l2 n_ex n_ops n_e n_x n_d n_i t_e t_x t_d t_i));
    return \%rv;
$$;


CREATE OR REPLACE FUNCTION cigar_stats_is_minor(RECORD)
RETURNS BOOLEAN LANGUAGE plperl STRICT IMMUTABLE AS 
$$
use strict;
use warnings;

my ($r) = @_;

# tide = trivial indel at end -- does not count as indel 
my $cc = $r->{'collapsed_cigar'};
return undef if not defined $cc;
my ($tide) = $cc =~ m/\d[DI]\d=$/ ? 1 : 0;

return (
	   ($r->{n_x} <= 10)
	   and ($r->{n_d} + $r->{n_i} <= 3 + $tide)
	   and ($r->{t_d} + $r->{t_i} <= 50)
	   )
	   ? 1 : 0;
$$;


CREATE OR REPLACE FUNCTION transcript_class(
	   sb_se_i_eq bool, sb_status_eq bool, s_refagree bool, b_refagree bool, s_trivial bool, b_trivial bool)
returns text
immutable
language sql as $$
select case
-- See https://docs.google.com/a/invitae.com/spreadsheet/ccc?key=0ArCkc7BhL450dDRZTmE0djk3bHIxRVdMMlF0WTBoV3c&rm=full#gid=7
-- Column U ("case SQL")
when (    sb_se_i_eq         AND     sb_status_eq         AND     s_refagree         AND     b_refagree         AND     s_trivial         AND     b_trivial        ) then 'A0'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND     s_refagree         AND NOT b_refagree         AND     s_trivial         AND NOT b_trivial        ) then 'A2'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND     s_refagree         AND NOT b_refagree         AND     s_trivial         AND     b_trivial        ) then 'A2'
when (    sb_se_i_eq         AND     sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND     s_trivial         AND     b_trivial        ) then 'B0'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND     s_refagree         AND     b_refagree IS NULL AND     s_trivial         AND     b_trivial IS NULL) then 'B2'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND     s_refagree IS NULL AND     b_refagree         AND     s_trivial IS NULL AND     b_trivial        ) then 'B4'
when (NOT sb_se_i_eq         AND     sb_status_eq         AND     s_refagree         AND     b_refagree         AND     s_trivial         AND     b_trivial        ) then 'C2'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND     s_trivial         AND NOT b_trivial        ) then 'C4'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND     s_trivial         AND     b_trivial        ) then 'C4'
when (NOT sb_se_i_eq         AND     sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND     s_trivial         AND NOT b_trivial        ) then 'C4'
when (NOT sb_se_i_eq         AND     sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND     s_trivial         AND     b_trivial        ) then 'C4'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND NOT s_refagree         AND     b_refagree IS NULL AND     s_trivial         AND     b_trivial IS NULL) then 'C5'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND     s_refagree IS NULL AND NOT b_refagree         AND     s_trivial IS NULL AND     b_trivial        ) then 'C5'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND NOT s_trivial         AND     b_trivial        ) then 'C6'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND     b_refagree         AND NOT s_trivial         AND     b_trivial        ) then 'C9'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND     b_refagree         AND     s_trivial         AND     b_trivial        ) then 'C9'
when (    sb_se_i_eq         AND     sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND NOT s_trivial         AND NOT b_trivial        ) then 'D'
when (NOT sb_se_i_eq         AND     sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND NOT s_trivial         AND NOT b_trivial        ) then 'E'
when (NOT sb_se_i_eq         AND NOT sb_status_eq         AND NOT s_refagree         AND NOT b_refagree         AND NOT s_trivial         AND NOT b_trivial        ) then 'E'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND NOT s_refagree         AND     b_refagree IS NULL AND NOT s_trivial         AND     b_trivial IS NULL) then 'E'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND     s_refagree IS NULL AND NOT b_refagree         AND     s_trivial IS NULL AND NOT b_trivial        ) then 'E'
when (    sb_se_i_eq IS NULL AND     sb_status_eq IS NULL AND     s_refagree IS NULL AND     b_refagree IS NULL AND     s_trivial IS NULL AND     b_trivial IS NULL) then 'F'
else NULL
END;
$$;
