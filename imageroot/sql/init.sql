-- NS8 XWiki module - MariaDB initialization
-- Run once at first container start (ignored on subsequent starts).
-- Grant XWiki user full privileges so it can create new schemas for sub-wikis.
GRANT ALL PRIVILEGES ON *.* TO 'xwiki'@'%' WITH GRANT OPTION;
