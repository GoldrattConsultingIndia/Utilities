sqlcmd -S localhost -U sa -P pass -d SymphonyZivame -Q "EXEC [dbo].[Client_RebuildReorgIndex] @page_count= 100, @Reorg_Min_Frag=10 , @Rebuild_Min_Frag=30"



