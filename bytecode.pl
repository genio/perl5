BEGIN {
  push @INC, './lib';
}
use strict;
my %alias_to = (
    U32 => [qw(PADOFFSET STRLEN)],
    I32 => [qw(SSize_t long)],
    U16 => [qw(OPCODE line_t short)],
    U8 => [qw(char)],
);

my @optype= qw(OP UNOP BINOP LOGOP LISTOP PMOP SVOP PADOP PVOP LOOP COP);

# Nullsv *must* come first in the following so that the condition
# ($$sv == 0) can continue to be used to test (sv == Nullsv).
my @specialsv = qw(Nullsv &PL_sv_undef &PL_sv_yes &PL_sv_no pWARN_ALL pWARN_NONE);

my (%alias_from, $from, $tos);
while (($from, $tos) = each %alias_to) {
    map { $alias_from{$_} = $from } @$tos;
}

my $c_header = <<'EOT';
/*
 *      Copyright (c) 1996-1999 Malcolm Beattie
 *
 *      You may distribute under the terms of either the GNU General Public
 *      License or the Artistic License, as specified in the README file.
 *
 */
/*
 * This file is autogenerated from bytecode.pl. Changes made here will be lost.
 */
EOT

my $perl_header;
($perl_header = $c_header) =~ s{[/ ]?\*/?}{#}g;

unlink "ext/ByteLoader/byterun.c", "ext/ByteLoader/byterun.h", "ext/B/B/Asmdata.pm";

#
# Start with boilerplate for Asmdata.pm
#
open(ASMDATA_PM, ">ext/B/B/Asmdata.pm") or die "ext/B/B/Asmdata.pm: $!";
print ASMDATA_PM $perl_header, <<'EOT';
package B::Asmdata;

our $VERSION = '1.00';

use Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(%insn_data @insn_name @optype @specialsv_name);
our(%insn_data, @insn_name, @optype, @specialsv_name);

EOT
print ASMDATA_PM <<"EOT";
\@optype = qw(@optype);
\@specialsv_name = qw(@specialsv);

# XXX insn_data is initialised this way because with a large
# %insn_data = (foo => [...], bar => [...], ...) initialiser
# I get a hard-to-track-down stack underflow and segfault.
EOT

#
# Boilerplate for byterun.c
#
open(BYTERUN_C, ">ext/ByteLoader/byterun.c") or die "ext/ByteLoader/byterun.c: $!";
print BYTERUN_C $c_header, <<'EOT';

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#define NO_XSLOCKS
#include "XSUB.h"

#include "byterun.h"
#include "bytecode.h"


static const int optype_size[] = {
EOT
my $i = 0;
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_C "    sizeof(%s),\n", $optype[$i], $i;
}
printf BYTERUN_C "    sizeof(%s)\n", $optype[$i], $i;
print BYTERUN_C <<'EOT';
};

void *
bset_obj_store(pTHX_ struct byteloader_state *bstate, void *obj, I32 ix)
{
    if (ix > bstate->bs_obj_list_fill) {
	Renew(bstate->bs_obj_list, ix + 32, void*);
	bstate->bs_obj_list_fill = ix + 31;
    }
    bstate->bs_obj_list[ix] = obj;
    return obj;
}

void
byterun(pTHX_ register struct byteloader_state *bstate)
{
    register int insn;
    U32 ix;
    SV *specialsv_list[6];

    BYTECODE_HEADER_CHECK;	/* croak if incorrect platform */
    New(666, bstate->bs_obj_list, 32, void*); /* set op objlist */
    bstate->bs_obj_list_fill = 31;

EOT

for my $i ( 0 .. $#specialsv ) {
    print BYTERUN_C "    specialsv_list[$i] = $specialsv[$i];\n";
}

print BYTERUN_C <<'EOT';

    while ((insn = BGET_FGETC()) != EOF) {
	switch (insn) {
EOT


my (@insn_name, $insn_num, $insn, $lvalue, $argtype, $flags, $fundtype);

while (<DATA>) {
    chop;
    s/#.*//;			# remove comments
    next unless length;
    if (/^%number\s+(.*)/) {
	$insn_num = $1;
	next;
    } elsif (/%enum\s+(.*?)\s+(.*)/) {
	create_enum($1, $2);	# must come before instructions
	next;
    }
    ($insn, $lvalue, $argtype, $flags) = split;
    $insn_name[$insn_num] = $insn;
    $fundtype = $alias_from{$argtype} || $argtype;

    #
    # Add the case statement and code for the bytecode interpreter in byterun.c
    #
    printf BYTERUN_C "\t  case INSN_%s:\t\t/* %d */\n\t    {\n",
	uc($insn), $insn_num;
    my $optarg = $argtype eq "none" ? "" : ", arg";
    if ($optarg) {
	printf BYTERUN_C "\t\t$argtype arg;\n\t\tBGET_%s(arg);\n", $fundtype;
    }
    if ($flags =~ /x/) {
	print BYTERUN_C "\t\tBSET_$insn($lvalue$optarg);\n";
    } elsif ($flags =~ /s/) {
	# Store instructions store to bytecode_obj_list[arg]. "lvalue" field is rvalue.
	print BYTERUN_C "\t\tBSET_OBJ_STORE($lvalue$optarg);\n";
    }
    elsif ($optarg && $lvalue ne "none") {
	print BYTERUN_C "\t\t$lvalue = arg;\n";
    }
    print BYTERUN_C "\t\tbreak;\n\t    }\n";

    #
    # Add the initialiser line for %insn_data in Asmdata.pm
    #
    print ASMDATA_PM <<"EOT";
\$insn_data{$insn} = [$insn_num, \\&PUT_$fundtype, "GET_$fundtype"];
EOT

    # Find the next unused instruction number
    do { $insn_num++ } while $insn_name[$insn_num];
}

#
# Finish off byterun.c
#
print BYTERUN_C <<'EOT';
	  default:
	    Perl_croak(aTHX_ "Illegal bytecode instruction %d\n", insn);
	    /* NOTREACHED */
	}
    }
}
EOT

#
# Write the instruction and optype enum constants into byterun.h
#
open(BYTERUN_H, ">ext/ByteLoader/byterun.h") or die "ext/ByteLoader/byterun.h: $!";
print BYTERUN_H $c_header, <<'EOT';
struct byteloader_fdata {
    SV	*datasv;
    int next_out;
    int	idx;
};

struct byteloader_state {
    struct byteloader_fdata	*bs_fdata;
    SV				*bs_sv;
    void			**bs_obj_list;
    int				bs_obj_list_fill;
    XPV				bs_pv;
    int				bs_iv_overflows;
};

int bl_getc(struct byteloader_fdata *);
int bl_read(struct byteloader_fdata *, char *, size_t, size_t);
extern void byterun(pTHX_ struct byteloader_state *);

enum {
EOT

my $add_enum_value = 0;
my $max_insn;
for $i ( 0 .. $#insn_name ) {
    $insn = uc($insn_name[$i]);
    if (defined($insn)) {
	$max_insn = $i;
	if ($add_enum_value) {
	    print BYTERUN_H "    INSN_$insn = $i,\t\t\t/* $i */\n";
	    $add_enum_value = 0;
	} else {
	    print BYTERUN_H "    INSN_$insn,\t\t\t/* $i */\n";
	}
    } else {
	$add_enum_value = 1;
    }
}

print BYTERUN_H "    MAX_INSN = $max_insn\n};\n";

print BYTERUN_H "\nenum {\n";
for ($i = 0; $i < @optype - 1; $i++) {
    printf BYTERUN_H "    OPt_%s,\t\t/* %d */\n", $optype[$i], $i;
}
printf BYTERUN_H "    OPt_%s\t\t/* %d */\n};\n\n", $optype[$i], $i;

#
# Finish off insn_data and create array initialisers in Asmdata.pm
#
print ASMDATA_PM <<'EOT';

my ($insn_name, $insn_data);
while (($insn_name, $insn_data) = each %insn_data) {
    $insn_name[$insn_data->[0]] = $insn_name;
}
# Fill in any gaps
@insn_name = map($_ || "unused", @insn_name);

1;

__END__

=head1 NAME

B::Asmdata - Autogenerated data about Perl ops, used to generate bytecode

=head1 SYNOPSIS

	use Asmdata;

=head1 DESCRIPTION

See F<ext/B/B/Asmdata.pm>.

=head1 AUTHOR

Malcolm Beattie, C<mbeattie@sable.ox.ac.uk>

=cut
EOT

__END__
# First set instruction ord("#") to read comment to end-of-line (sneaky)
%number 35
comment		arg			comment_t
# Then make ord("\n") into a no-op
%number 10
nop		none			none
# Now for the rest of the ordinary ones, beginning with \0 which is
# ret so that \0-terminated strings can be read properly as bytecode.
%number 0
#
#opcode		lvalue					argtype		flags	
#
ret		none					none		x
ldsv		bstate->bs_sv				svindex
ldop		PL_op					opindex
stsv		bstate->bs_sv				U32		s
stop		PL_op					U32		s
stpv		bstate->bs_pv.xpv_pv			U32		x
ldspecsv	bstate->bs_sv				U8		x
newsv		bstate->bs_sv				U8		x
newop		PL_op					U8		x
newopn		PL_op					U8		x
newpv		none					PV
pv_cur		bstate->bs_pv.xpv_cur			STRLEN
pv_free		bstate->bs_pv				none		x
sv_upgrade	bstate->bs_sv				char		x
sv_refcnt	SvREFCNT(bstate->bs_sv)			U32
sv_refcnt_add	SvREFCNT(bstate->bs_sv)			I32		x
sv_flags	SvFLAGS(bstate->bs_sv)			U32
xrv		SvRV(bstate->bs_sv)			svindex
xpv		bstate->bs_sv				none		x
xiv32		SvIVX(bstate->bs_sv)			I32
xiv64		SvIVX(bstate->bs_sv)			IV64
xnv		SvNVX(bstate->bs_sv)			NV
xlv_targoff	LvTARGOFF(bstate->bs_sv)		STRLEN
xlv_targlen	LvTARGLEN(bstate->bs_sv)		STRLEN
xlv_targ	LvTARG(bstate->bs_sv)			svindex
xlv_type	LvTYPE(bstate->bs_sv)			char
xbm_useful	BmUSEFUL(bstate->bs_sv)			I32
xbm_previous	BmPREVIOUS(bstate->bs_sv)		U16
xbm_rare	BmRARE(bstate->bs_sv)			U8
xfm_lines	FmLINES(bstate->bs_sv)			I32
xio_lines	IoLINES(bstate->bs_sv)			long
xio_page	IoPAGE(bstate->bs_sv)			long
xio_page_len	IoPAGE_LEN(bstate->bs_sv)		long
xio_lines_left	IoLINES_LEFT(bstate->bs_sv)	       	long
xio_top_name	IoTOP_NAME(bstate->bs_sv)		pvcontents
xio_top_gv	*(SV**)&IoTOP_GV(bstate->bs_sv)		svindex
xio_fmt_name	IoFMT_NAME(bstate->bs_sv)		pvcontents
xio_fmt_gv	*(SV**)&IoFMT_GV(bstate->bs_sv)		svindex
xio_bottom_name	IoBOTTOM_NAME(bstate->bs_sv)		pvcontents
xio_bottom_gv	*(SV**)&IoBOTTOM_GV(bstate->bs_sv)	svindex
xio_subprocess	IoSUBPROCESS(bstate->bs_sv)		short
xio_type	IoTYPE(bstate->bs_sv)			char
xio_flags	IoFLAGS(bstate->bs_sv)			char
xcv_stash	*(SV**)&CvSTASH(bstate->bs_sv)		svindex
xcv_start	CvSTART(bstate->bs_sv)			opindex
xcv_root	CvROOT(bstate->bs_sv)			opindex
xcv_gv		*(SV**)&CvGV(bstate->bs_sv)		svindex
xcv_file	CvFILE(bstate->bs_sv)			pvindex
xcv_depth	CvDEPTH(bstate->bs_sv)			long
xcv_padlist	*(SV**)&CvPADLIST(bstate->bs_sv)	svindex
xcv_outside	*(SV**)&CvOUTSIDE(bstate->bs_sv)	svindex
xcv_flags	CvFLAGS(bstate->bs_sv)			U16
av_extend	bstate->bs_sv				SSize_t		x
av_push		bstate->bs_sv				svindex		x
xav_fill	AvFILLp(bstate->bs_sv)			SSize_t
xav_max		AvMAX(bstate->bs_sv)			SSize_t
xav_flags	AvFLAGS(bstate->bs_sv)			U8
xhv_riter	HvRITER(bstate->bs_sv)			I32
xhv_name	HvNAME(bstate->bs_sv)			pvcontents
hv_store	bstate->bs_sv				svindex		x
sv_magic	bstate->bs_sv				char		x
mg_obj		SvMAGIC(bstate->bs_sv)->mg_obj		svindex
mg_private	SvMAGIC(bstate->bs_sv)->mg_private	U16
mg_flags	SvMAGIC(bstate->bs_sv)->mg_flags	U8
mg_pv		SvMAGIC(bstate->bs_sv)			pvcontents	x
xmg_stash	*(SV**)&SvSTASH(bstate->bs_sv)		svindex
gv_fetchpv	bstate->bs_sv				strconst	x
gv_stashpv	bstate->bs_sv				strconst	x
gp_sv		GvSV(bstate->bs_sv)			svindex
gp_refcnt	GvREFCNT(bstate->bs_sv)			U32
gp_refcnt_add	GvREFCNT(bstate->bs_sv)			I32		x
gp_av		*(SV**)&GvAV(bstate->bs_sv)		svindex
gp_hv		*(SV**)&GvHV(bstate->bs_sv)		svindex
gp_cv		*(SV**)&GvCV(bstate->bs_sv)		svindex
gp_file		GvFILE(bstate->bs_sv)			pvindex
gp_io		*(SV**)&GvIOp(bstate->bs_sv)		svindex
gp_form		*(SV**)&GvFORM(bstate->bs_sv)		svindex
gp_cvgen	GvCVGEN(bstate->bs_sv)			U32
gp_line		GvLINE(bstate->bs_sv)			line_t
gp_share	bstate->bs_sv				svindex		x
xgv_flags	GvFLAGS(bstate->bs_sv)			U8
op_next		PL_op->op_next				opindex
op_sibling	PL_op->op_sibling			opindex
op_ppaddr	PL_op->op_ppaddr			strconst	x
op_targ		PL_op->op_targ				PADOFFSET
op_type		PL_op					OPCODE		x
op_seq		PL_op->op_seq				U16
op_flags	PL_op->op_flags				U8
op_private	PL_op->op_private			U8
op_first	cUNOP->op_first				opindex
op_last		cBINOP->op_last				opindex
op_other	cLOGOP->op_other			opindex
op_pmreplroot	cPMOP->op_pmreplroot			opindex
op_pmreplrootgv	*(SV**)&cPMOP->op_pmreplroot		svindex
op_pmreplstart	cPMOP->op_pmreplstart			opindex
op_pmnext	*(OP**)&cPMOP->op_pmnext		opindex
pregcomp	PL_op					pvcontents	x
op_pmflags	cPMOP->op_pmflags			U16
op_pmpermflags	cPMOP->op_pmpermflags			U16
op_sv		cSVOP->op_sv				svindex
op_padix	cPADOP->op_padix			PADOFFSET
op_pv		cPVOP->op_pv				pvcontents
op_pv_tr	cPVOP->op_pv				op_tr_array
op_redoop	cLOOP->op_redoop			opindex
op_nextop	cLOOP->op_nextop			opindex
op_lastop	cLOOP->op_lastop			opindex
cop_label	cCOP->cop_label				pvindex
cop_stashpv	cCOP					pvindex		x
cop_file	cCOP					pvindex		x
cop_seq		cCOP->cop_seq				U32
cop_arybase	cCOP->cop_arybase			I32
cop_line	cCOP					line_t		x
cop_warnings	cCOP->cop_warnings			svindex
main_start	PL_main_start				opindex
main_root	PL_main_root				opindex
curpad		PL_curpad				svindex		x
push_begin	PL_beginav				svindex		x
push_init	PL_initav				svindex		x
push_end	PL_endav				svindex		x
