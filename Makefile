########################################################
# Configuration variables

PYTHON ?= python3
PYVENV ?= .venv

all: igraph

########################################################
# Main package

top_srcdir=cigraph
VERSION=$(shell tools/getversion.sh)

# We put the version number in a file, so that we can detect
# if it changes

version_number: force
	@echo '$(VERSION)' | cmp -s - $@ || echo '$(VERSION)' > $@

# Source files from the C library, we don't need BLAS/LAPACK
# because they are included in R and ARPACK, because
# we use the Fortran files for that. We don't need F2C, either.

CSRC := $(shell cd $(top_srcdir) ; git ls-files --full-name src | \
	      grep -v "^src/lapack/" | grep -v "^src/f2c" | \
	      grep -v Makefile.am)

$(CSRC): src/%: $(top_srcdir)/src/%
	mkdir -p $(@D) && cp $< $@

# Include files from the C library

CINC := $(shell cd $(top_srcdir) ; git ls-files --full-name include)
CINC2 := $(patsubst include/%, src/include/%, $(CINC))

$(CINC2): src/include/%: $(top_srcdir)/include/%
	mkdir -p $(@D) && cp $< $@

# Files generated by flex/bison

PARSER := $(shell cd $(top_srcdir) ; git ls-files --full-name src | \
	    grep -E '\.(l|y)$$')
PARSER1 := $(patsubst src/%.l, src/%.c, $(PARSER))
PARSER2 := $(patsubst src/%.y, src/%.c, $(PARSER1))

YACC=bison -d
LEX=flex

%.c: %.y
	$(YACC) $<
	mv -f y.tab.c $@
	mv -f y.tab.h $(@:.c=.h)

%.c: %.l
	$(LEX) $<
	mv -f lex.yy.c $@

# Create Python virtualenv for Stimulus

venv: $(PYVENV)/stamp

$(PYVENV)/stamp: tools/build-requirements.txt
	$(PYTHON) -m venv $(PYVENV)
	$(PYVENV)/bin/pip install -r $<
	touch $(PYVENV)/stamp

# Apply possible patches

patches: $(CSRC) $(CINC2) $(PARSER2)
	if [ -d "patches" ]; then \
		find patches -type f -name '*.patch' -print0 | sort -z | xargs -t -0 -n 1 tools/apply-patch.sh; \
	fi
	tools/fix-lexers.sh

# C files generated by C configure

CGEN = src/igraph_threading.h src/igraph_version.h

src/igraph_threading.h: $(top_srcdir)/include/igraph_threading.h.in
	mkdir -p src
	sed 's/@HAVE_TLS@/0/g' $< >$@

src/igraph_version.h: $(top_srcdir)/include/igraph_version.h.in
	mkdir -p src
	sed 's/@PACKAGE_VERSION@/'$(VERSION)'/g' $< >$@

# R source and doc files

RSRC := $(shell git ls-files R doc inst demo NEWS cleanup.win configure.win)

# ARPACK Fortran sources

ARPACK := $(shell git ls-files tools/arpack)
ARPACK2 := $(patsubst tools/arpack/%, src/%, $(ARPACK))

$(ARPACK2): src/%: tools/arpack/%
	mkdir -p $(@D) && cp $< $@

# libuuid

UUID := $(shell git ls-files tools/uuid)
UUID2 := $(patsubst tools/uuid/%, src/uuid/%, $(UUID))

$(UUID2): src/uuid/%: tools/uuid/%
	mkdir -p $(@D) && cp $< $@

# R files that are generated/copied

RGEN = R/auto.R src/rinterface.c src/rinterface.h \
	src/rinterface_extra.c src/lazyeval.c src/init.c src/Makevars.in \
	configure src/config.h.in src/Makevars.win \
	DESCRIPTION

# Simpleraytracer

RAY := $(shell git ls-files vendor/simpleraytracer)
RAY2 := $(patsubst vendor/simpleraytracer/%, src/simpleraytracer/%, $(RAY))

$(RAY2): src/%: vendor/%
	mkdir -p $(@D) && cp $< $@

# Files generated by stimulus

src/rinterface.c: $(top_srcdir)/interfaces/functions.def \
		tools/stimulus/rinterface.c.in  \
		tools/stimulus/types-RC.def
	$(PYVENV)/bin/stimulus \
           -f $(top_srcdir)/interfaces/functions.def \
           -i tools/stimulus/rinterface.c.in \
           -o src/rinterface.c \
           -t tools/stimulus/types-RC.def \
           -l RC

R/auto.R: $(top_srcdir)/interfaces/functions.def tools/stimulus/auto.R.in \
		tools/stimulus/types-RR.def
	$(PYVENV)/bin/stimulus \
           -f $(top_srcdir)/interfaces/functions.def \
           -i tools/stimulus/auto.R.in \
           -o R/auto.R \
           -t tools/stimulus/types-RR.def \
           -l RR

# configure files

configure src/config.h.in: configure.ac
	autoheader; autoconf

# DESCRIPTION file, we re-generate it only if the VERSION number
# changes or $< changes

DESCRIPTION: tools/stimulus/DESCRIPTION version_number
	sed 's/^Version: .*$$/Version: '$(VERSION)'/' $< > $@

src/rinterface.h: tools/stimulus/rinterface.h
	mkdir -p src
	cp $< $@

src/rinterface_extra.c: tools/stimulus/rinterface_extra.c
	mkdir -p src
	cp $< $@

src/lazyeval.c: tools/stimulus/lazyeval.c
	mkdir -p src
	cp $< $@

src/init.c: tools/stimulus/init.c
	mkdir -p src
	cp $< $@

# This is the list of all object files in the R package,
# we write it to a file to be able to depend on it.
# Makevars.in and Makevars.win are only regenerated if
# the list of object files changes.

OBJECTS := $(shell echo $(CSRC) $(ARPACK) $(RAY) $(UUID)   |             \
		tr ' ' '\n' |                                            \
	        grep -E '\.(c|cpp|cc|f|l|y)$$' | 			 \
		grep -F -v f2c/arithchk.c | grep -F -v f2c_dummy.c |	 \
		sed 's/\.[^\.][^\.]*$$/.o/' | 			 	 \
		sed 's/^src\///' | sed 's/^tools\/arpack\///' |		 \
		sed 's/^tools\///' | 					 \
		sed 's/^vendor\///' | 					 \
		sed 's/^optional\///') rinterface.o rinterface_extra.o lazyeval.o

object_files: force
	@echo '$(OBJECTS)' | cmp -s - $@ || echo '$(OBJECTS)' > $@

configure.ac: %: tools/stimulus/%
	sed 's/@VERSION@/'$(VERSION)'/g' $< >$@

src/Makevars.win src/Makevars.in: src/%: tools/stimulus/% \
		object_files
	sed 's/@VERSION@/'$(VERSION)'/g' $< >$@
	printf "%s" "OBJECTS=" >> $@
	cat object_files >> $@

# We have everything, here we go

igraph: igraph_$(VERSION).tar.gz

igraph_$(VERSION).tar.gz: venv patches $(CSRC) $(CINC2) $(PARSER2) $(RSRC) $(RGEN) \
			  $(CGEN) $(RAY2) $(ARPACK2) $(UUID2)
	rm -f src/config.h
	rm -f src/Makevars
	touch src/config.h
	mkdir -p man
	tools/builddocs.sh
	Rscript -e 'devtools::build(path = ".")'

#############

check: igraph_$(VERSION).tar.gz
	_R_CHECK_FORCE_SUGGESTS_=0 R CMD check --as-cran $<

check-links: igraph_$(VERSION).tar.gz
	mkdir -p html-docs
	R CMD INSTALL --html --no-R --no-configure --no-inst --no-libs --no-exec --no-test-load -l html-docs $<
	$(PYVENV)/bin/linkchecker html-docs/igraph/html/00Index.html ; rm -rf html-docs

check-rhub: igraph
	Rscript -e 'rhub::check_for_cran()'

clean:
	@rm -f  DESCRIPTION
	@rm -f  NAMESPACE
	@rm -f  R/auto.R
	@rm -rf autom4te.cache/
	@rm -f  config.log
	@rm -f  config.status
	@rm -f  configure
	@rm -f  igraph_*.tar.gz
	@rm -f  igraph_*.tgz
	@rm -rf man/*.Rd
	@rm -f  object_files
	@rm -rf src/
	@rm -rf version_number
	@rm -f  configure.ac

distclean: clean
	@rm -rf $(PYVENV)

.PHONY: all igraph force clean check check-rhub check-links

.NOTPARALLEL:
