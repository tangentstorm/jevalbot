#!/bin/sh
cd ~/jevalbot
# thanks, http://stackoverflow.com/questions/696839 !
until ./j-bot; do
  echo "j-bot crashed with exit code $?.  Respawning.." >&2
  sleep 1
done
