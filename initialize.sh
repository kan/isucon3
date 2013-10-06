#/bin/sh
mysql -uisucon isucon -e 'select * from memos' > /dev/null;
mysql -uisucon isucon -e 'select * from users' > /dev/null;
mysql -uisucon isucon -e 'alter table memos add index up(user,is_private)' > /dev/null;
mysql -uisucon isucon -e 'alter table memos add index created_at_idx(created_at)' > /dev/null;
mysql -uisucon isucon -e 'alter table memos add index recent(created_at)' > /dev/null;
cat $HOME/webapp/perl/warmup_url.txt | xargs -P5 -t -n1 /usr/bin/curl > /dev/null
