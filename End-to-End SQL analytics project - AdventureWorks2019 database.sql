-- STEP 1: Create / replace scalar UDF for profit margin
IF OBJECT_ID('dbo.GetProfitMargin', 'FN') IS NOT NULL
    DROP FUNCTION dbo.GetProfitMargin;
GO

CREATE FUNCTION dbo.GetProfitMargin(@ProductID INT)
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @Cost MONEY, @Price MONEY, @Margin DECIMAL(10,2);

    SELECT 
        @Cost = StandardCost, 
        @Price = ListPrice
    FROM Production.Product
    WHERE ProductID = @ProductID;

    SET @Margin = CASE WHEN @Price > 0 
                       THEN ((@Price - @Cost) / @Price) * 100 
                       ELSE 0 END;

    RETURN @Margin;
END;
GO



-- STEP 2: Create / replace view for territory-level performance
IF OBJECT_ID('Sales.TerritoryPerformance', 'V') IS NOT NULL
    DROP VIEW Sales.TerritoryPerformance;
GO

CREATE VIEW Sales.TerritoryPerformance
AS
SELECT 
    t.Name AS Territory,
    SUM(soh.TotalDue) AS TotalRevenue,
    COUNT(soh.SalesOrderID) AS OrderCount
FROM Sales.SalesOrderHeader soh
INNER JOIN Sales.SalesTerritory t
    ON soh.TerritoryID = t.TerritoryID
GROUP BY t.Name
HAVING SUM(soh.TotalDue) > 1000000;
GO

-- STEP 3: 

-- Drop temp table if it exists from a previous run
IF OBJECT_ID('tempdb..#CategorySales') IS NOT NULL
    DROP TABLE #CategorySales;

-- Declare target year (change as needed)
DECLARE @Year INT = 2013;

----------------------------------------------------------
-- Temp table: Company product-category revenue for @Year
----------------------------------------------------------
SELECT 
    pc.Name AS Category,
    SUM(sod.LineTotal) AS Revenue
INTO #CategorySales
FROM Sales.SalesOrderDetail sod
INNER JOIN Production.Product p ON sod.ProductID = p.ProductID
INNER JOIN Production.ProductSubcategory ps ON p.ProductSubcategoryID = ps.ProductSubcategoryID
INNER JOIN Production.ProductCategory pc ON ps.ProductCategoryID = pc.ProductCategoryID
INNER JOIN Sales.SalesOrderHeader soh ON sod.SalesOrderID = soh.SalesOrderID
WHERE YEAR(soh.OrderDate) = @Year
GROUP BY pc.Name
HAVING SUM(sod.LineTotal) > 200000;  

----------------------------------------------------------
-- CTEs: top customers, favorite month, top category/territory/product
----------------------------------------------------------
;WITH 
CustomerSpending AS (
    SELECT 
        c.CustomerID,
        SUM(soh.TotalDue) AS TotalSpent
    FROM Sales.SalesOrderHeader soh
    INNER JOIN Sales.Customer c ON soh.CustomerID = c.CustomerID
    WHERE YEAR(soh.OrderDate) = @Year
    GROUP BY c.CustomerID
),
RankedCustomers AS (
    SELECT 
        cs.CustomerID,
        cs.TotalSpent,
        RANK() OVER (ORDER BY cs.TotalSpent DESC) AS RankCustomer
    FROM CustomerSpending cs
),
CustomerMonthlyAgg AS (
    SELECT 
        soh.CustomerID,
        MONTH(soh.OrderDate) AS OrderMonth,
        SUM(soh.TotalDue) AS MonthRevenue
    FROM Sales.SalesOrderHeader soh
    WHERE YEAR(soh.OrderDate) = @Year
    GROUP BY soh.CustomerID, MONTH(soh.OrderDate)
),
TopMonthPerCustomer AS (
    SELECT CustomerID, OrderMonth, MonthRevenue
    FROM (
        SELECT CustomerID, OrderMonth, MonthRevenue,
               ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY MonthRevenue DESC) AS RN
        FROM CustomerMonthlyAgg
    ) t
    WHERE RN = 1
),
CustomerCategoryAgg AS (
    SELECT 
        soh.CustomerID,
        pc.Name AS Category,
        SUM(sod.LineTotal) AS CategoryRevenue
    FROM Sales.SalesOrderDetail sod
    INNER JOIN Sales.SalesOrderHeader soh ON sod.SalesOrderID = soh.SalesOrderID
    INNER JOIN Production.Product p ON sod.ProductID = p.ProductID
    INNER JOIN Production.ProductSubcategory ps ON p.ProductSubcategoryID = ps.ProductSubcategoryID
    INNER JOIN Production.ProductCategory pc ON ps.ProductCategoryID = pc.ProductCategoryID
    WHERE YEAR(soh.OrderDate) = @Year
    GROUP BY soh.CustomerID, pc.Name
),
TopCategoryPerCustomer AS (
    SELECT CustomerID, Category, CategoryRevenue
    FROM (
        SELECT CustomerID, Category, CategoryRevenue,
               ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY CategoryRevenue DESC) AS RN
        FROM CustomerCategoryAgg
    ) t
    WHERE RN = 1
),
CustomerTerritoryAgg AS (
    SELECT 
        soh.CustomerID,
        t.Name AS Territory,
        SUM(soh.TotalDue) AS TerritoryRevenue
    FROM Sales.SalesOrderHeader soh
    LEFT JOIN Sales.SalesTerritory t ON soh.TerritoryID = t.TerritoryID
    WHERE YEAR(soh.OrderDate) = @Year
    GROUP BY soh.CustomerID, t.Name
),
TopTerritoryPerCustomer AS (
    SELECT CustomerID, Territory, TerritoryRevenue
    FROM (
        SELECT CustomerID, Territory, TerritoryRevenue,
               ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY TerritoryRevenue DESC) AS RN
        FROM CustomerTerritoryAgg
    ) t
    WHERE RN = 1
),
CustomerTopProductAgg AS (
    SELECT 
        soh.CustomerID,
        sod.ProductID,
        SUM(sod.LineTotal) AS ProductRevenue
    FROM Sales.SalesOrderDetail sod
    INNER JOIN Sales.SalesOrderHeader soh ON sod.SalesOrderID = soh.SalesOrderID
    WHERE YEAR(soh.OrderDate) = @Year
    GROUP BY soh.CustomerID, sod.ProductID
),
TopProductPerCustomer AS (
    SELECT CustomerID, ProductID, ProductRevenue
    FROM (
        SELECT CustomerID, ProductID, ProductRevenue,
               ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY ProductRevenue DESC) AS RN
        FROM CustomerTopProductAgg
    ) t
    WHERE RN = 1
)

----------------------------------------------------------
-- Final report: top 5 customers for @Year
----------------------------------------------------------
SELECT TOP 5
    rc.RankCustomer,
    p.FirstName + ' ' + p.LastName AS CustomerName,
    rc.TotalSpent,
    tm.OrderMonth AS FavoriteMonth,
    tm.MonthRevenue AS FavoriteMonthRevenue,
    tcp.Category AS TopCategory,
    tcp.CategoryRevenue AS CategoryRevenue,
    ttp.Territory AS TopTerritory,
    ttp.TerritoryRevenue AS TerritoryRevenue,
    prod.Name AS TopProductName,
    dbo.GetProfitMargin(prod.ProductID) AS TopProductProfitMargin
FROM RankedCustomers rc
INNER JOIN Sales.Customer c ON rc.CustomerID = c.CustomerID
INNER JOIN Person.Person p ON c.PersonID = p.BusinessEntityID
LEFT JOIN TopMonthPerCustomer tm ON rc.CustomerID = tm.CustomerID
LEFT JOIN TopCategoryPerCustomer tcp ON rc.CustomerID = tcp.CustomerID
LEFT JOIN TopTerritoryPerCustomer ttp ON rc.CustomerID = ttp.CustomerID
LEFT JOIN TopProductPerCustomer tpp ON rc.CustomerID = tpp.CustomerID
LEFT JOIN Production.Product prod ON tpp.ProductID = prod.ProductID
ORDER BY rc.RankCustomer;

----------------------------------------------------------
-- Show category sales (temp table)
----------------------------------------------------------
SELECT * 
FROM #CategorySales
ORDER BY Revenue DESC;

-- Clean up
DROP TABLE #CategorySales;
