# full reset
bash purge_local.sh

# base system
bash init_local.sh

# accounting DB
export DB_ROOT_PASS="rootpass_change_me"
bash scripts/10_enable_accounting_mariadb_docker.sh

# slurmdbd + accounting
bash scripts/11_configure_slurmdbd.sh

# create customer + user
bash scripts/12_create_accounts_users.sh

# verification

ss -lntp | grep 6819
sudo sacctmgr show cluster
scontrol show config | grep AccountingStorage
J=$(sbatch --parsable --wrap="echo hi; sleep 2")
sleep 3
sacct -X -j "$J"
