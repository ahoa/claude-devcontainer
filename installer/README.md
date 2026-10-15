# installer/

The parts of `install.sh`, by facet. `install.sh` sources them once it knows
where the template is, so a pipe install and a checkout run the same code.
They share the globals of `install.sh` and are not scripts of their own.

- `prompt.sh` — the five questions and the prompt helpers they share
- `detect.sh` — what an earlier install answered, name conflicts, the template commit
- `migrate.sh` — migrations from earlier template layouts
- `write.sh` — the file writer, the version stamp and the summary
