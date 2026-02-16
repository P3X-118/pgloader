# pgloader build tool

APP_NAME := "pgloader"
VERSION := "3.6.10"
CL := "sbcl"
BUILDDIR := "build"
BUNDLEDIST := "2022-02-20"
BUNDLENAME := "pgloader-bundle-" + VERSION
BUNDLEDIR := BUILDDIR + "/bundle/" + BUNDLENAME
BUNDLE := BUILDDIR + "/" + BUNDLENAME + ".tgz"
BUNDLETESTD := BUILDDIR + "/bundle/test"
DEBUILD_ROOT := "/tmp/pgloader"

QLDIR := BUILDDIR + "/quicklisp"
LIBS := BUILDDIR + "/libs.stamp"
MANIFEST := BUILDDIR + "/manifest.ql"
LATEST := BUILDDIR + "/pgloader-latest.tgz"

BUILDAPP_SBCL := BUILDDIR + "/bin/buildapp.sbcl"
BUILDAPP_CCL := BUILDDIR + "/bin/buildapp.ccl"

EXE := if os() == "windows" { ".exe" } else { "" }
DYNSIZE := if os() == "windows" { "1024" } else { "16384" }

PGLOADER := BUILDDIR + "/bin/" + APP_NAME + EXE
BUILDAPP := if CL == "sbcl" { BUILDAPP_SBCL } else { BUILDAPP_CCL }

CL_OPTS := if CL == "sbcl" { "--noinform --no-sysinit --no-userinit" } else { "--no-init" }

_default:
    @just --list

all: pgloader

clean:
    rm -rf {{ LIBS }} {{ QLDIR }} {{ MANIFEST }} {{ BUILDAPP }} {{ PGLOADER }} \
        buildapp.log build/bundle/* build/pgloader-bundle* build/quicklisp.lisp docs/_build
    make -C test clean

quicklisp:
    mkdir -p {{ BUILDDIR }}
    curl -o {{ BUILDDIR }}/quicklisp.lisp http://beta.quicklisp.org/quicklisp.lisp
    {{ CL }} {{ CL_OPTS }} --load {{ BUILDDIR }}/quicklisp.lisp \
             --load src/getenv.lisp \
             --eval '(quicklisp-quickstart:install :path "{{ BUILDDIR }}/quicklisp" :proxy (getenv "http_proxy"))' \
             --eval '(quit)'

docker:
    @if docker image inspect legitservices/pgloader:{{ VERSION }} >/dev/null 2>&1; then \
        echo "Image legitservices/pgloader:{{ VERSION }} already exists, skipping build"; \
    else \
        docker build -t legitservices/pgloader:latest -t legitservices/pgloader:{{ VERSION }} .; \
    fi

docker-push: docker
    docker push legitservices/pgloader:latest
    docker push legitservices/pgloader:{{ VERSION }}

clones qldir=QLDIR:
    git clone --depth 1 https://github.com/qitab/qmynd.git {{ qldir }}/local-projects/qmynd
    git clone --depth 1 https://github.com/dimitri/cl-ixf.git {{ qldir }}/local-projects/cl-ixf
    git clone --depth 1 https://github.com/dimitri/cl-db3.git {{ qldir }}/local-projects/cl-db3
    git clone --depth 1 https://github.com/AccelerationNet/cl-csv.git {{ qldir }}/local-projects/cl-csv

libs: quicklisp
    {{ CL }} {{ CL_OPTS }} --load {{ QLDIR }}/setup.lisp \
             --eval '(push :pgloader-image *features*)' \
             --eval '(setf *print-circle* t *print-pretty* t)' \
             --eval '(push "{{ invocation_directory() }}/" ql:*local-project-directories*)' \
             --eval '(ql:quickload "pgloader")' \
             --eval '(quit)'
    touch {{ LIBS }}

manifest: libs
    {{ CL }} {{ CL_OPTS }} --load {{ QLDIR }}/setup.lisp \
             --eval '(ql:write-asdf-manifest-file "{{ MANIFEST }}")' \
             --eval '(quit)'

buildapp: quicklisp
    mkdir -p {{ BUILDDIR }}/bin
    {{ CL }} {{ CL_OPTS }} --load {{ QLDIR }}/setup.lisp \
             --eval '(ql:quickload "buildapp")' \
             --eval '(buildapp:build-buildapp "{{ BUILDAPP }}")' \
             --eval '(quit)'

pgloader: manifest buildapp
    mkdir -p {{ BUILDDIR }}/bin
    {{ BUILDAPP }} --logfile /tmp/build.log \
                  --require sb-posix \
                  --require sb-bsd-sockets \
                  --require sb-rotate-byte \
                  --sbcl {{ CL }} \
                  --asdf-path . \
                  --asdf-tree {{ QLDIR }}/local-projects \
                  --manifest-file {{ MANIFEST }} \
                  --asdf-tree {{ QLDIR }}/dists \
                  --asdf-path . \
                  --load-system cffi \
                  --load-system cl+ssl \
                  --load-system mssql \
                  --load src/hooks.lisp \
                  --load-system {{ APP_NAME }} \
                  --entry pgloader:main \
                  --dynamic-space-size {{ DYNSIZE }} \
                  --output {{ PGLOADER }}.tmp
    mv {{ PGLOADER }}.tmp {{ PGLOADER }}

test: pgloader
    make -C test regress PGLOADER=$(realpath {{ PGLOADER }}) CL={{ CL }}

save:
    {{ CL }} {{ CL_OPTS }} --load ./src/save.lisp

clean-bundle:
    rm -rf {{ BUNDLEDIR }}
    rm -rf {{ BUNDLETESTD }}/{{ BUNDLENAME }}/*

bundle: clean-bundle
    mkdir -p {{ BUNDLETESTD }}
    mkdir -p {{ BUNDLEDIR }}
    {{ CL }} {{ CL_OPTS }} --load {{ QLDIR }}/setup.lisp \
             --eval '(defvar *bundle-dir* "{{ BUNDLEDIR }}")' \
             --eval '(defvar *pwd* "{{ invocation_directory() }}/")' \
             --eval '(defvar *ql-dist* "{{ BUNDLEDIST }}")' \
             --load bundle/ql.lisp
    echo "{{ VERSION }}" > {{ BUNDLEDIR }}/version.sexp
    cp bundle/README.md {{ BUNDLEDIR }}
    cp bundle/save.lisp {{ BUNDLEDIR }}
    sed -e s/%VERSION%/{{ VERSION }}/ < bundle/Makefile > {{ BUNDLEDIR }}/Makefile
    git archive --format=tar --prefix=pgloader-{{ VERSION }}/ master | tar -C {{ BUNDLEDIR }}/local-projects/ -xf -
    just clones {{ BUNDLEDIR }}
    tar -C build/bundle \
          --exclude bin \
          --exclude test/sqlite \
          -czf {{ BUNDLE }} {{ BUNDLENAME }}
    tar -C {{ BUNDLETESTD }} -xf {{ BUNDLE }}
    make -C {{ BUNDLETESTD }}/{{ BUNDLENAME }}
    {{ BUNDLETESTD }}/{{ BUNDLENAME }}/bin/pgloader --version

deb:
    mkdir -p {{ DEBUILD_ROOT }} && rm -rf {{ DEBUILD_ROOT }}/*
    rsync -Ca --exclude 'build' \
          --exclude '.vagrant' \
          ./ {{ DEBUILD_ROOT }}/
    cd {{ DEBUILD_ROOT }} && make -f debian/rules orig
    cd {{ DEBUILD_ROOT }} && debuild -us -uc -sa
    cp -a /tmp/pgloader_* /tmp/cl-pgloader* build/

rpm:
    mkdir -p {{ DEBUILD_ROOT }} && rm -rf {{ DEBUILD_ROOT }}
    rsync -Ca --exclude=build/* ./ {{ DEBUILD_ROOT }}/
    cd /tmp && tar czf {{ env_var("HOME") }}/rpmbuild/SOURCES/pgloader-{{ VERSION }}.tar.gz pgloader
    cd {{ DEBUILD_ROOT }} && rpmbuild -ba pgloader.spec
    cp -a {{ env_var("HOME") }}/rpmbuild/SRPMS/*rpm build
    cp -a {{ env_var("HOME") }}/rpmbuild/RPMS/x86_64/*rpm build

pkg:
    mkdir -p {{ DEBUILD_ROOT }} && rm -rf {{ DEBUILD_ROOT }}/*
    mkdir -p {{ DEBUILD_ROOT }}/usr/local/bin/
    mkdir -p {{ DEBUILD_ROOT }}/usr/local/share/man/man1/
    cp ./pgloader.1 {{ DEBUILD_ROOT }}/usr/local/share/man/man1/
    cp ./build/bin/pgloader {{ DEBUILD_ROOT }}/usr/local/bin/
    pkgbuild --identifier org.tapoueh.pgloader \
             --root {{ DEBUILD_ROOT }} \
             --version {{ VERSION }} \
             ./build/pgloader-{{ VERSION }}.pkg

latest:
    git archive --format=tar --prefix=pgloader-{{ VERSION }}/ v{{ VERSION }} | gzip -9 > {{ LATEST }}

check: test
