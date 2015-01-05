# Makefile for cbstream

# settings

CC = gcc
OFLAG = -O
CFL =
JSOFTWARE_LIBRARY = -L . -lj

# rules

.DELETE_ON_ERROR:
RM = rm -f
CFLAGS = -Wall -g $(OFLAG) $(CFL)
LIBCXX = -lstdc++
CXXFLAGS = $(CFLAGS)
CXX = $(CC)
INSTALL = install

all: jep

install: install-jeval

upload: jevalbot.tgz
	rsync -vz $+ omnibus2.math.bme.hu:~/a/html/pu/

install-jeval: jeval.rb
	test -d ~/local/lib/jeval || mkdir ~/local/lib/jeval
	$(INSTALL) jep jevalrun ~/local/bin/
	$(INSTALL) jeval.rb hevalj-conf.yaml evalj-conf.yaml ~/local/lib/jeval/

jevalbot.tgz: jeval.rb jeval-default-conf.yaml evalj-conf.yaml jep.c Makefile
	tar czf $@ $+

interp.o: interp.cpp

interp: interp.o
	$(CC) $(CFLAGS) $(LIBCXX) -o $@ $+

s.o: s.c
	$(CC) $(CFLAGS) -c -o $@ $<

s: s.o
	$(CC) $(CFLAGS) -L ~/local/lib -lj601 -o $@ $+

jep.o: jep.c
	$(CC) $(CFLAGS) -c -o $@ $<

jep: jep.o
	$(CC) $(CFLAGS) $(JSOFTWARE_LIBRARY) -o $@ $+

clean:
	$(RM) *.o interp jep s


#END
