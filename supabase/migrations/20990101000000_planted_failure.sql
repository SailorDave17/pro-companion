-- #41 criterion 1, proven on PR #102's own CI: this migration must fail to apply and fail the
-- local-stack job. It is reverted in the next commit.
select 1/0;
