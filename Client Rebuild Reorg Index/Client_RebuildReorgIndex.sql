--DROP TABLE FragData,FragDataHistory 
--EXEC [dbo].[Client_RebuildReorgIndex] @page_count= 100, @Reorg_Min_Frag=30 , @Rebuild_Min_Frag=30
--SELECT * FROM FragData
--SELECT * FROM FragDataHistory order by UpdateDate desc

IF (OBJECT_ID('[dbo].[Client_RebuildReorgIndex]') IS NOT NULL)
BEGIN
	DROP PROCEDURE [dbo].[Client_RebuildReorgIndex]
END
GO
CREATE PROCEDURE [dbo].[Client_RebuildReorgIndex]
(
	@page_count			BIGINT = 100,
	@Reorg_Min_Frag		INT	= 10 ,	--less than 100 AND less than @Rebuild_Min_Frag
	@Rebuild_Min_Frag	INT = 30	--less than 100 AND greater than @Reorg_Min_Frag
)
AS 
BEGIN
SET NOCOUNT ON
	DECLARE @Cmd				NVARCHAR(Max)
	DECLARE @ErrorMessage		NVARCHAR(900) 
	DECLARE @Cur_ErrorMessage	NVARCHAR(900)	
	
	DECLARE @dbid INT;
	SELECT @dbid = DB_ID();
	
	IF OBJECT_ID('tempdb..#data_spaces') IS NOT NULL
		DROP TABLE #data_spaces
	CREATE TABLE #data_spaces
	(
		ID				INT IDENTITY(1,1),
		data_space_id	INT,
		Type			NVARCHAR(10)
	)

	IF OBJECT_ID('FragDataHistory') IS NULL
		CREATE TABLE FragDataHistory
		(
			RunDate							Smalldatetime,
			SchemaName						NVARCHAR(100),
			TableName						NVARCHAR(100),
			IndexName						NVARCHAR(100),
			PartitionNum					INT,
			PartitionRows					BIGINT,
			PreAvgFragPct					Decimal(18,5),
			PostAvgFragPct					Decimal(18,5),
			PrePageCt						BIGINT,
			PostPageCt						BIGINT,
			DiffPageCt						BIGINT,
			DiffPageCtPct					Decimal(18,5),
			RebuildReorgQry					NVARCHAR(500),
			ErrMsg							NVARCHAR(500)
		)

	IF OBJECT_ID('FragData') IS NULL
		CREATE TABLE FragData
		(
			ID								INT IDENTITY(1,1),
			RunDate							Smalldatetime,
			SchemaName						NVARCHAR(100),
			TableName						NVARCHAR(100),
			IndexName						NVARCHAR(100),
			PartitionNum					INT,
			PartitionRows					BIGINT,
			PreAvgFragPct					Decimal(18,5),
			PostAvgFragPct					Decimal(18,5),
			PrePageCt						BIGINT,
			PostPageCt						BIGINT,
			DiffPageCt						BIGINT,
			DiffPageCtPct					Decimal(18,5),
			RebuildReorgQry					NVARCHAR(500),
			ErrMsg							NVARCHAR(500)
		)

	INSERT INTO FragDataHistory
	(RunDate,SchemaName,TableName,IndexName,PartitionNum,PartitionRows,PreAvgFragPct,PostAvgFragPct,
	PrePageCt,PostPageCt,DiffPageCt,DiffPageCtPct,RebuildReorgQry,ErrMsg)
	SELECT 
		RunDate				,
		SchemaName			,
		TableName			,
		IndexName			,
		PartitionNum		,
		PartitionRows		,
		PreAvgFragPct		,
		PostAvgFragPct		,
		PrePageCt			,
		PostPageCt			,
		DiffPageCt			,
		DiffPageCtPct		,
		RebuildReorgQry		,
		ErrMsg
	FROM FragData
	
	TRUNCATE TABLE FragData
	
	INSERT INTO #data_spaces (data_space_id,Type)
	SELECT data_space_id,Type FROM sys.data_spaces WHERE type='PS'
	
	--Insertion of partition index records for rebuild Reorg Starts

	DECLARE @ID INT, @data_space_id INT, @Type NVARCHAR(10);
	BEGIN TRANSACTION;	
	
		DECLARE Dataspaces CURSOR FOR 
		    SELECT  ID, data_space_id, Type
		    FROM #data_spaces
			ORDER BY ID
		
		    OPEN Dataspaces;
		    FETCH NEXT FROM Dataspaces INTO @ID, @data_space_id, @Type;
		 
		    WHILE @@FETCH_STATUS = 0
		    BEGIN	
			BEGIN TRY
	
				INSERT INTO FragData
				(RunDate,SchemaName,TableName,IndexName,PartitionNum,PartitionRows,PreAvgFragPct,PrePageCt,RebuildReorgQry)
				SELECT  CAST(GETDATE() AS SMALLDATETIME)	,
						dbschemas.[name] AS 'Schema',
				        dbtables.[name] AS 'Table',
				        dbindexes.[name] AS 'Index',
				        indexstats.partition_number,
				        part.rows AS partition_rows,
				        indexstats.avg_fragmentation_in_percent,
				        indexstats.page_count,       
						CASE 
							WHEN indexstats.page_count <= @page_count OR indexstats.avg_fragmentation_in_percent < @Reorg_Min_Frag 
								THEN '--Do nothing. It''s good'
							WHEN indexstats.avg_fragmentation_in_percent BETWEEN @Reorg_Min_Frag AND @Rebuild_Min_Frag 
								THEN 'ALTER INDEX ['+dbindexes.[name]+'] ON ['+dbschemas.[name]+'].['+dbtables.[name]+'] REORGANIZE  Partition = '+ CAST(indexstats.partition_number AS NVARCHAR(10)) + ' ;'
							ELSE 
								'ALTER INDEX ['+dbindexes.[name]+'] ON ['+dbschemas.[name]+'].['+dbtables.[name]+'] REBUILD Partition = ' + CAST(indexstats.partition_number AS NVARCHAR(10)) + ' ;'
				        END  AS [Rebuild Query]
				FROM    sys.dm_db_index_physical_stats (@dbid, NULL, NULL, NULL, NULL) AS indexstats
				JOIN    sys.tables dbtables ON dbtables.[object_id] = indexstats.[object_id]
				JOIN    sys.schemas dbschemas ON dbtables.[schema_id] = dbschemas.[schema_id]
				JOIN    sys.indexes AS dbindexes ON dbindexes.[object_id] = indexstats.[object_id] AND indexstats.index_id = dbindexes.index_id
				JOIN    sys.partitions part ON dbindexes.object_id = part.object_id AND dbindexes.index_id = part.index_id AND indexstats.partition_number = part.partition_number
				WHERE   indexstats.database_id = @dbid
				AND     indexstats.index_id > 0
				AND		dbindexes.data_space_id in ( @data_space_id)
				AND		indexstats.page_count > @page_count 
				AND		indexstats.avg_fragmentation_in_percent > @Reorg_Min_Frag 
				GROUP BY dbschemas.[name], dbtables.[name], dbindexes.[name], indexstats.partition_number, indexstats.avg_fragmentation_in_percent, indexstats.page_count, part.rows, dbindexes.data_space_id,indexstats.index_id
				ORDER BY indexstats.avg_fragmentation_in_percent DESC;

			END TRY
			BEGIN CATCH
			    -- Rollback in case of error
			    ROLLBACK TRANSACTION;
				BEGIN TRANSACTION;  			
			   
			   -- Error handling
			    SET @ErrorMessage = ERROR_MESSAGE();									
				UPDATE FragData
				SET ErrMsg = 'Error: ' + @ErrorMessage
				WHERE ID = @ID

			END CATCH;
	
			FETCH NEXT FROM Dataspaces INTO @ID, @data_space_id, @Type;	
		    END
	CLOSE Dataspaces;
	DEALLOCATE Dataspaces;	
	COMMIT TRANSACTION;
	
	--Insertion of partition index records for rebuild Reorg Ends

	--Insertion of non-partition index records for rebuild Reorg Starts
	INSERT INTO FragData
	(RunDate,SchemaName,TableName,IndexName,PartitionNum,PartitionRows,PreAvgFragPct,PrePageCt,RebuildReorgQry)
	SELECT  CAST(GETDATE() AS SMALLDATETIME)	,
			dbschemas.[name] AS 'Schema',
	        dbtables.[name] AS 'Table',
	        dbindexes.[name] AS 'Index',
	        indexstats.partition_number,
	        part.rows AS partition_rows,
	        indexstats.avg_fragmentation_in_percent,
	        indexstats.page_count,
	        CASE 
		        WHEN indexstats.page_count < @page_count OR indexstats.avg_fragmentation_in_percent < @Reorg_Min_Frag 
					THEN '--Do nothing. It''s good'
	            WHEN indexstats.avg_fragmentation_in_percent BETWEEN @Reorg_Min_Frag AND @Rebuild_Min_Frag 
					THEN 'ALTER INDEX ['+dbindexes.[name]+'] ON ['+dbschemas.[name]+'].['+dbtables.[name]+'] REORGANIZE ;'
	            ELSE 
					'ALTER INDEX ['+dbindexes.[name]+'] ON ['+dbschemas.[name]+'].['+dbtables.[name]+'] REBUILD ;'
	        END AS [Rebuild Query]
	FROM    sys.dm_db_index_physical_stats (@dbid, NULL, NULL, NULL, NULL) AS indexstats
	JOIN    sys.tables dbtables ON dbtables.[object_id] = indexstats.[object_id]
	JOIN    sys.schemas dbschemas ON dbtables.[schema_id] = dbschemas.[schema_id]
	JOIN    sys.indexes AS dbindexes ON dbindexes.[object_id] = indexstats.[object_id] AND indexstats.index_id = dbindexes.index_id
	JOIN    sys.partitions part ON dbindexes.object_id = part.object_id AND dbindexes.index_id = part.index_id AND indexstats.partition_number = part.partition_number
	WHERE   indexstats.database_id = @dbid
	AND     indexstats.index_id > 0
	AND		dbindexes.data_space_id NOT IN (SELECT data_space_id FROM #data_spaces)
	AND		indexstats.page_count > @page_count 
	AND		indexstats.avg_fragmentation_in_percent > @Reorg_Min_Frag 	
	GROUP BY dbschemas.[name], dbtables.[name], dbindexes.[name], indexstats.partition_number, indexstats.avg_fragmentation_in_percent, indexstats.page_count, part.rows, dbindexes.data_space_id,indexstats.index_id
	
	--Insertion of non-partition index records for rebuild Reorg Ends

	--loop for running Rebuild and Reorg and Update StatisticsSQL

	DECLARE @IDNo INT, @Rebuild_Reorg_Query NVARCHAR(200),@TableName NVARCHAR(200), @UpdateStatisticsSQL NVARCHAR(200), @SchemaName NVARCHAR(200);
	BEGIN TRANSACTION;
	
		DECLARE Cur_FragData CURSOR FOR 
		    SELECT  ID, RebuildReorgQry,TableName, SchemaName
		    FROM FragData
			ORDER BY ID
	
		    OPEN Cur_FragData;
		    FETCH NEXT FROM Cur_FragData INTO @IDNo, @Rebuild_Reorg_Query,@TableName,@SchemaName;		 
		    WHILE @@FETCH_STATUS = 0
		    BEGIN		
				BEGIN TRY	
				
					--PRINT(@Rebuild_Reorg_Query)
					EXEC (@Rebuild_Reorg_Query)
					
					SET @UpdateStatisticsSQL = 'UPDATE STATISTICS ' + QUOTENAME(@SchemaName)+ '.'+QUOTENAME(@TableName)
					
					--PRINT(@UpdateStatisticsSQL)
					EXEC sp_executesql @UpdateStatisticsSQL

				END TRY
				BEGIN CATCH
				    -- Rollback in case of error

				    ROLLBACK TRANSACTION;
					BEGIN TRANSACTION;
				   
				   -- Error handling
				     SET @Cur_ErrorMessage = ERROR_MESSAGE();					
					UPDATE FragData
					SET ErrMsg = ISNULL(ErrMsg,'') + 'Error: ' + @Cur_ErrorMessage
					WHERE ID =@IDNo
					
					COMMIT TRANSACTION;
					BEGIN TRANSACTION;
					
				END CATCH;	
				
				FETCH NEXT FROM Cur_FragData INTO @IDNo, @Rebuild_Reorg_Query,@TableName,@SchemaName;
		    END
	CLOSE Cur_FragData;
	DEALLOCATE Cur_FragData;	
	COMMIT TRANSACTION;
	
	UPDATE	Frag
	SET		Frag.PostAvgFragPct	= indexstats.avg_fragmentation_in_percent,
			Frag.PostPageCt		= indexstats.page_count
	FROM    sys.dm_db_index_physical_stats (@dbid, NULL, NULL, NULL, NULL) AS indexstats
	JOIN    sys.tables dbtables ON dbtables.[object_id] = indexstats.[object_id]
	JOIN    sys.schemas dbschemas ON dbtables.[schema_id] = dbschemas.[schema_id]
	JOIN    sys.indexes AS dbindexes ON dbindexes.[object_id] = indexstats.[object_id] AND indexstats.index_id = dbindexes.index_id
	JOIN    sys.partitions part ON dbindexes.object_id = part.object_id AND dbindexes.index_id = part.index_id AND indexstats.partition_number = part.partition_number
	JOIN	FragData Frag	ON Frag.TableName = dbtables.[name]
							AND Frag.IndexName = dbindexes.[name]
							AND Frag.PartitionNum = indexstats.partition_number
							AND Frag.PartitionRows = part.rows
	WHERE   indexstats.database_id = @dbid

	UPDATE FragData
	SET DiffPageCt = PrePageCt - PostPageCt,
		DiffPageCtPct = (CAST((PrePageCt - PostPageCt) AS DECIMAL(18,5))/PrePageCt) * 100

SET NOCOUNT OFF
END