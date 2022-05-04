import Foundation
import WordPressFlux

enum StatsSummaryTimeIntervalDataAsAWeek {
    case thisWeek(data: StatsSummaryTimeIntervalData)
    case prevWeek(data: StatsSummaryTimeIntervalData)
}

/// The view model used by Stats Insights.
///
class SiteStatsInsightsViewModel: Observable {

    // MARK: - Properties

    let changeDispatcher = Dispatcher<Void>()

    private weak var siteStatsInsightsDelegate: SiteStatsInsightsDelegate?

    private let insightsStore: StatsInsightsStore
    private let periodStore: StatsPeriodStore
    private var insightsReceipt: Receipt?
    private var insightsChangeReceipt: Receipt?
    private var insightsToShow = [InsightType]()
    private var lastRequestedDate: Date
    private var lastRequestedPeriod: StatsPeriodUnit

    private let pinnedItemStore: SiteStatsPinnedItemStore?
    private let itemToDisplay: SiteStatsPinnable?
    private var isNudgeCompleted: Bool {
        guard let pinnedItemStore = pinnedItemStore, let item = itemToDisplay, item is GrowAudienceCell.HintType else {
            return false
        }
        return !pinnedItemStore.shouldShow(item)
    }

    private var periodReceipt: Receipt?
    private var periodChangeReceipt: Receipt?

    private typealias Style = WPStyleGuide.Stats

    weak var statsLineChartViewDelegate: StatsLineChartViewDelegate?

    private var mostRecentChartData: StatsSummaryTimeIntervalData? {
        didSet {
            if oldValue == nil {
                guard let mostRecentChartData = mostRecentChartData else {
                    return
                }

                currentEntryIndex = mostRecentChartData.summaryData.lastIndex(where: { $0.periodStartDate <= self.lastRequestedDate })
                        ?? max(mostRecentChartData.summaryData.count - 1, 0)
            }
        }
    }

    private var currentEntryIndex: Int = 0

    // MARK: - Constructor

    init(insightsToShow: [InsightType],
         insightsDelegate: SiteStatsInsightsDelegate,
         insightsStore: StatsInsightsStore,
         pinnedItemStore: SiteStatsPinnedItemStore?,
         periodStore: StatsPeriodStore = StoreContainer.shared.statsPeriod) {
        self.siteStatsInsightsDelegate = insightsDelegate
        self.insightsToShow = insightsToShow
        self.insightsStore = insightsStore
        self.pinnedItemStore = pinnedItemStore
        self.periodStore = periodStore
        let viewsCount = insightsStore.getAllTimeStats()?.viewsCount ?? 0
        self.itemToDisplay = pinnedItemStore?.itemToDisplay(for: viewsCount)
        self.lastRequestedDate = Date()
        self.lastRequestedPeriod = StatsPeriodUnit.day

        insightsChangeReceipt = self.insightsStore.onChange { [weak self] in
            self?.emitChange()
        }

        if FeatureFlag.statsNewInsights.enabled {
            periodChangeReceipt = self.periodStore.onChange { [weak self] in
                self?.emitChange()
            }
        }
    }

    func fetchInsights() {
        insightsReceipt = insightsStore.query(.insights)
    }

    func startFetchingPeriodOverview() {
        periodReceipt = periodStore.query(.periods(date: lastRequestedDate, period: lastRequestedPeriod))
        periodStore.actionDispatcher.dispatch(PeriodAction.refreshPeriodOverviewData(date: lastRequestedDate,
                period: lastRequestedPeriod,
                forceRefresh: true))
    }

    // MARK: - Refresh Data

    /// This method will trigger a refresh of insights data, provided that we're not already
    /// performing a refresh and that we haven't refreshed within the last 5 minutes.
    /// To override this caching and request the latest data (for example, when as the result
    /// of a pull to refresh action), you can pass a `forceRefresh` value of `true` here.
    ///
    func refreshInsights(forceRefresh: Bool = false) {
        ActionDispatcher.dispatch(InsightAction.refreshInsights(forceRefresh: forceRefresh))
    }

    // MARK: - Table Model

    func tableViewModel() -> ImmuTable {

        var tableRows = [ImmuTableRow]()

        if insightsToShow.isEmpty ||
            (fetchingFailed() && !containsCachedData()) {
            return ImmuTable.Empty
        }

        let summaryErrorBlock: AsyncBlock<[ImmuTableRow]> = {
            return [PeriodEmptyCellHeaderRow(),
                    StatsErrorRow(rowStatus: .error, statType: .period)]
        }

        insightsToShow.forEach { insightType in
            let errorBlock = {
                return StatsErrorRow(rowStatus: .error, statType: .insights)
            }

            switch insightType {
            case .viewsVisitors:
                tableRows.append(contentsOf: blocks(for: .viewsVisitors,
                        type: .period,
                        status: periodStore.summaryStatus,
                        checkingCache: { [weak self] in
                            return self?.mostRecentChartData != nil
                        },
                        block: { [weak self] in
                            return self?.overviewTableRows() ?? summaryErrorBlock()
                        }, loading: {
                    return [PeriodEmptyCellHeaderRow(),
                            StatsGhostChartImmutableRow()]
                }, error: summaryErrorBlock))
            case .growAudience:
                tableRows.append(blocks(for: .growAudience,
                                        type: .insights,
                                        status: insightsStore.allTimeStatus,
                                        block: {
                                            let nudge = itemToDisplay as? GrowAudienceCell.HintType ?? GrowAudienceCell.HintType.social
                                            let viewsCount = insightsStore.getAllTimeStats()?.viewsCount ?? 0
                                            return GrowAudienceRow(hintType: nudge,
                                                                   allTimeViewsCount: viewsCount,
                                                                   isNudgeCompleted: isNudgeCompleted,
                                                                   siteStatsInsightsDelegate: siteStatsInsightsDelegate)
                }, loading: {
                    return StatsGhostGrowAudienceImmutableRow()
                }, error: errorBlock))
            case .latestPostSummary:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsLatestPostSummary,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .latestPostSummary,
                                        type: .insights,
                                        status: insightsStore.lastPostSummaryStatus,
                                        block: {
                                            return LatestPostSummaryRow(summaryData: insightsStore.getLastPostInsight(),
                                                                        chartData: insightsStore.getPostStats(),
                                                                        siteStatsInsightsDelegate: siteStatsInsightsDelegate)
                }, loading: {
                    return StatsGhostChartImmutableRow()
                }, error: errorBlock))
            case .allTimeStats:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsAllTime,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .allTimeStats,
                                        type: .insights,
                                        status: insightsStore.allTimeStatus,
                                        block: {
                                            return TwoColumnStatsRow(dataRows: createAllTimeStatsRows(),
                                                                     statSection: .insightsAllTime,
                                                                     siteStatsInsightsDelegate: nil)
                }, loading: {
                    return StatsGhostTwoColumnImmutableRow()
                }, error: errorBlock))
            case .followersTotals:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsFollowerTotals,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .followersTotals,
                                        type: .insights,
                                        status: insightsStore.followersTotalsStatus,
                                        block: {
                                            return TwoColumnStatsRow(dataRows: createTotalFollowersRows(),
                                                                     statSection: .insightsFollowerTotals,
                                                                     siteStatsInsightsDelegate: nil)
                }, loading: {
                    return StatsGhostTwoColumnImmutableRow()
                }, error: errorBlock))
            case .mostPopularTime:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsMostPopularTime,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .mostPopularTime,
                                        type: .insights,
                                        status: insightsStore.annualAndMostPopularTimeStatus,
                                        block: {
                    if FeatureFlag.statsNewInsights.enabled {
                        return MostPopularTimeInsightStatsRow(data: createMostPopularStatsRowData(),
                                                 siteStatsInsightsDelegate: nil)
                    } else {
                        return TwoColumnStatsRow(dataRows: createMostPopularStatsRows(),
                                                 statSection: .insightsMostPopularTime,
                                                 siteStatsInsightsDelegate: nil)
                    }
                }, loading: {
                    return StatsGhostTwoColumnImmutableRow()
                }, error: errorBlock))
            case .tagsAndCategories:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsTagsAndCategories,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .tagsAndCategories,
                                        type: .insights,
                                        status: insightsStore.tagsAndCategoriesStatus,
                                        block: {
                                            return TopTotalsInsightStatsRow(itemSubtitle: StatSection.insightsTagsAndCategories.itemSubtitle,
                                                                            dataSubtitle: StatSection.insightsTagsAndCategories.dataSubtitle,
                                                                            dataRows: createTagsAndCategoriesRows(),
                                                                            siteStatsInsightsDelegate: siteStatsInsightsDelegate)
                }, loading: {
                    return StatsGhostTopImmutableRow()
                }, error: errorBlock))
            case .annualSiteStats:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsAnnualSiteStats,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .annualSiteStats,
                                        type: .insights,
                                        status: insightsStore.annualAndMostPopularTimeStatus,
                                        block: {
                                            return TwoColumnStatsRow(dataRows: createAnnualRows(),
                                                                     statSection: .insightsAnnualSiteStats,
                                                                     siteStatsInsightsDelegate: siteStatsInsightsDelegate)
                }, loading: {
                    return StatsGhostTwoColumnImmutableRow()
                }, error: errorBlock))
            case .comments:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsCommentsPosts,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .comments,
                                        type: .insights,
                                        status: insightsStore.commentsInsightStatus,
                                        block: {
                                            return createCommentsRow()
                }, loading: {
                    return StatsGhostTabbedImmutableRow()
                }, error: errorBlock))
            case .followers:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsFollowersWordPress,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .followers,
                                        type: .insights,
                                        status: insightsStore.followersTotalsStatus,
                                        block: {
                                            return createFollowersRow()
                }, loading: {
                    return StatsGhostTabbedImmutableRow()
                }, error: errorBlock))
            case .todaysStats:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsTodaysStats,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .todaysStats,
                                        type: .insights,
                                        status: insightsStore.todaysStatsStatus,
                                        block: {
                                            return TwoColumnStatsRow(dataRows: createTodaysStatsRows(),
                                                                     statSection: .insightsTodaysStats,
                                                                     siteStatsInsightsDelegate: nil)
                }, loading: {
                    return StatsGhostTwoColumnImmutableRow()
                }, error: errorBlock))
            case .postingActivity:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsPostingActivity,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .postingActivity,
                                        type: .insights,
                                        status: insightsStore.postingActivityStatus,
                                        block: {
                                            return createPostingActivityRow()
                }, loading: {
                    return StatsGhostPostingActivitiesImmutableRow()
                }, error: errorBlock))
            case .publicize:
                tableRows.append(InsightCellHeaderRow(statSection: StatSection.insightsPublicize,
                                                      siteStatsInsightsDelegate: siteStatsInsightsDelegate))
                tableRows.append(blocks(for: .publicize,
                                        type: .insights,
                                        status: insightsStore.publicizeFollowersStatus,
                                        block: {
                                            return TopTotalsInsightStatsRow(itemSubtitle: StatSection.insightsPublicize.itemSubtitle,
                                                                            dataSubtitle: StatSection.insightsPublicize.dataSubtitle,
                                                                            dataRows: createPublicizeRows(),
                                                                            siteStatsInsightsDelegate: nil)
                }, loading: {
                    return StatsGhostTopImmutableRow()
                }, error: errorBlock))
            default:
                break
            }
        }

        tableRows.append(TableFooterRow())
        tableRows.append(AddInsightRow(dataRow: createAddInsightRow(), siteStatsInsightsDelegate: siteStatsInsightsDelegate))

        tableRows.append(TableFooterRow())

        if FeatureFlag.statsNewAppearance.enabled {
            // Remove any header rows for the new appearance
            tableRows = tableRows.filter({ !($0 is InsightCellHeaderRow || $0 is TableFooterRow) })

            let sections = tableRows.map({ ImmuTableSection(rows: [$0]) })
            return ImmuTable(sections: sections)
        }

        return ImmuTable(sections: [
            ImmuTableSection(
                rows: tableRows)
            ])
    }

    func isFetchingOverview() -> Bool {
        return insightsStore.isFetchingOverview
    }

    func fetchingFailed() -> Bool {
        return insightsStore.fetchingFailed(for: .insights)
    }

    func containsCachedData() -> Bool {
        return insightsStore.containsCachedData(for: insightsToShow)
    }

    func yearlyPostingActivity(from date: Date = Date()) -> [[PostingStreakEvent]] {
        return insightsStore.getYearlyPostingActivityFrom(date: date)
    }

    func annualInsightsYear() -> Int? {
        return insightsStore.getAnnualAndMostPopularTime()?.annualInsightsYear
    }

    func updateInsightsToShow(insights: [InsightType]) {
        insightsToShow = insights
    }

    func markEmptyStatsNudgeAsCompleted() {
        guard let item = itemToDisplay else {
            return
        }
        pinnedItemStore?.markPinnedItemAsHidden(item)
    }

    var followTopicsViewController: ReaderSelectInterestsViewController {
        let configuration = ReaderSelectInterestsConfiguration(title: NSLocalizedString("Follow topics", comment: "Screen title. Reader select interests title label text."),
                                                               subtitle: nil,
                                                               buttonTitle: nil,
                                                               loading: NSLocalizedString("Following new topics...", comment: "Label displayed to the user while loading their selected interests")
        )

        let context = ContextManager.sharedInstance().mainContext
        let topics: [ReaderTagTopic]
        if let fetchRequest = ReaderTagTopic.tagsFetchRequest as? NSFetchRequest<ReaderTagTopic>,
           let fetchedTopics = try? context.fetch(fetchRequest) {
            topics = fetchedTopics
        } else {
            topics = []
        }

        return ReaderSelectInterestsViewController(configuration: configuration, topics: topics)
    }
}

// MARK: - Private Extension

private extension SiteStatsInsightsViewModel {

    struct AllTimeStats {
        static let postsTitle = NSLocalizedString("Posts", comment: "All Time Stats 'Posts' label")
        static let viewsTitle = NSLocalizedString("Views", comment: "All Time Stats 'Views' label")
        static let visitorsTitle = NSLocalizedString("Visitors", comment: "All Time Stats 'Visitors' label")
        static let bestViewsEverTitle = NSLocalizedString("Best views ever", comment: "All Time Stats 'Best views ever' label")
    }

    struct MostPopularStats {
        static let bestDay = NSLocalizedString("Best Day", comment: "'Best Day' label for Most Popular stat.")
        static let bestHour = NSLocalizedString("Best Hour", comment: "'Best Hour' label for Most Popular stat.")
        static let viewPercentage = NSLocalizedString(
            "stats.insights.mostPopularCard.viewPercentage",
            value: "%d%% of views",
            comment: "Label showing the percentage of views to a user's site which fall on a particular day."
        )
    }

    struct FollowerTotals {
        static let total = NSLocalizedString("Total", comment: "Label for total followers")
        static let wordPress = NSLocalizedString("WordPress.com", comment: "Label for WordPress.com followers")
        static let email = NSLocalizedString("Email", comment: "Label for email followers")
        static let social = NSLocalizedString("Social", comment: "Follower Totals label for social media followers")
    }

    struct TodaysStats {
        static let viewsTitle = NSLocalizedString("Views", comment: "Today's Stats 'Views' label")
        static let visitorsTitle = NSLocalizedString("Visitors", comment: "Today's Stats 'Visitors' label")
        static let likesTitle = NSLocalizedString("Likes", comment: "Today's Stats 'Likes' label")
        static let commentsTitle = NSLocalizedString("Comments", comment: "Today's Stats 'Comments' label")
    }

    // MARK: - Create Table Rows

    func overviewTableRows() -> [ImmuTableRow] {
        var tableRows = [ImmuTableRow]()

        let periodSummary = periodStore.getSummary()

        if mostRecentChartData == nil {
            mostRecentChartData = periodSummary
        } else if let mostRecentChartData = mostRecentChartData,
                  let periodSummary = periodSummary,
                  mostRecentChartData.periodEndDate == periodSummary.periodEndDate {
            self.mostRecentChartData = periodSummary
        } else if let periodSummary = periodSummary, let chartData = mostRecentChartData, periodSummary.periodEndDate > chartData.periodEndDate {
            mostRecentChartData = chartData
        }

        let periodDate = self.lastRequestedDate
        let period = StatsPeriodUnit.week

        let viewsData = intervalData(summaryType: .views)
        let viewsSegmentData = StatsSegmentedControlData(segmentTitle: StatSection.periodOverviewViews.tabTitle,
                                                         segmentData: viewsData.count,
                                                         segmentPrevData: viewsData.prevCount,
                                                         difference: viewsData.difference,
                                                         date: periodDate,
                                                         period: period,
                                                         analyticsStat: .statsOverviewTypeTappedViews,
                                                         accessibilityHint: StatSection.periodOverviewViews.tabAccessibilityHint,
                                                         differencePercent: viewsData.percentage)

        let visitorsData = intervalData(summaryType: .visitors)
        let visitorsSegmentData = StatsSegmentedControlData(segmentTitle: StatSection.periodOverviewVisitors.tabTitle,
                                                            segmentData: visitorsData.count,
                                                            segmentPrevData: visitorsData.prevCount,
                                                            difference: visitorsData.difference,
                                                            date: periodDate,
                                                            period: period,
                                                            analyticsStat: .statsOverviewTypeTappedViews,
                                                            accessibilityHint: StatSection.periodOverviewViews.tabAccessibilityHint,
                                                            differencePercent: visitorsData.percentage)

        var lineChartData = [LineChartDataConvertible]()
        var lineChartStyling = [LineChartStyling]()

        if let chartData = mostRecentChartData {
            let splitSummaryTimeIntervalData = SiteStatsInsightsViewModel.splitStatsSummaryTimeIntervalData(chartData)
            let viewsChart = InsightsLineChart(data: splitSummaryTimeIntervalData, filterDimension: .views)
            lineChartData.append(contentsOf: viewsChart.lineChartData)
            lineChartStyling.append(contentsOf: viewsChart.lineChartStyling)

            let visitorsChart = InsightsLineChart(data: splitSummaryTimeIntervalData, filterDimension: .visitors)
            lineChartData.append(contentsOf: visitorsChart.lineChartData)
            lineChartStyling.append(contentsOf: visitorsChart.lineChartStyling)

            var xAxisDates = [Date]()
            splitSummaryTimeIntervalData.forEach { week in
                switch week {
                case .thisWeek(let data):
                    xAxisDates = data.summaryData.map { $0.periodStartDate }
                default:
                    break
                }
            }

            let row = ViewsVisitorsRow(
                    segmentsData: [viewsSegmentData, visitorsSegmentData],
                    chartData: lineChartData,
                    chartStyling: lineChartStyling,
                    period: lastRequestedPeriod,
                    statsLineChartViewDelegate: statsLineChartViewDelegate,
                    xAxisDates: xAxisDates
            )
            tableRows.append(row)
        }

        return tableRows
    }

    func intervalData(summaryType: StatsSummaryType) -> (count: Int, prevCount: Int, difference: Int, percentage: Int) {
        guard let chartData = mostRecentChartData else {
            return (0, 0, 0, 0)
        }

        let splitSummaryTimeIntervalData = SiteStatsInsightsViewModel.splitStatsSummaryTimeIntervalData(chartData)

        var currentCount: Int = 0
        var previousCount: Int = 0

        splitSummaryTimeIntervalData.forEach { week in
            switch week {
            case .thisWeek(let data):
                switch summaryType {
                case .views:
                    currentCount = data.summaryData.compactMap({$0.viewsCount}).reduce(0, +)
                case .visitors:
                    currentCount = data.summaryData.compactMap({$0.visitorsCount}).reduce(0, +)
                default:
                    break
                }
            case .prevWeek(let data):
                switch summaryType {
                case .views:
                    previousCount = data.summaryData.compactMap({$0.viewsCount}).reduce(0, +)
                case .visitors:
                    previousCount = data.summaryData.compactMap({$0.visitorsCount}).reduce(0, +)
                default:
                    break
                }
            }
        }

        let difference = currentCount - previousCount
        var roundedPercentage = 0

        if previousCount > 0 {
            let percentage = (Float(difference) / Float(previousCount)) * 100
            roundedPercentage = Int(round(percentage))
        }

        return (currentCount, previousCount, difference, roundedPercentage)
    }

    func createAllTimeStatsRows() -> [StatsTwoColumnRowData] {
        guard let allTimeInsight = insightsStore.getAllTimeStats() else {
            return []
        }

        let totalCounts = allTimeInsight.viewsCount +
                          allTimeInsight.visitorsCount +
                          allTimeInsight.postsCount +
                          allTimeInsight.bestViewsPerDayCount

        guard totalCounts > 0 else {
            return []
        }

        var dataRows = [StatsTwoColumnRowData]()

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AllTimeStats.viewsTitle,
                                                   leftColumnData: allTimeInsight.viewsCount.abbreviatedString(),
                                                   rightColumnName: AllTimeStats.visitorsTitle,
                                                   rightColumnData: allTimeInsight.visitorsCount.abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AllTimeStats.postsTitle,
                                                   leftColumnData: allTimeInsight.postsCount.abbreviatedString(),
                                                   rightColumnName: AllTimeStats.bestViewsEverTitle,
                                                   rightColumnData: allTimeInsight.bestViewsPerDayCount.abbreviatedString()))

        return dataRows
    }


    func createMostPopularStatsRowData() -> StatsMostPopularTimeData? {
        guard let mostPopularStats = insightsStore.getAnnualAndMostPopularTime(),
              let dayString = mostPopularStats.formattedMostPopularDay(),
              let timeString = mostPopularStats.formattedMostPopularTime(),
              mostPopularStats.mostPopularDayOfWeekPercentage > 0
        else {
            return nil
        }

        let dayPercentage = String(format: MostPopularStats.viewPercentage, mostPopularStats.mostPopularDayOfWeekPercentage)
        let hourPercentage = String(format: MostPopularStats.viewPercentage, mostPopularStats.mostPopularHourPercentage)

        return StatsMostPopularTimeData(mostPopularDayTitle: MostPopularStats.bestDay, mostPopularTimeTitle: MostPopularStats.bestHour, mostPopularDay: dayString, mostPopularTime: timeString.uppercased(), dayPercentage: dayPercentage, timePercentage: hourPercentage)
    }

    func createMostPopularStatsRows() -> [StatsTwoColumnRowData] {
        guard let mostPopularStats = insightsStore.getAnnualAndMostPopularTime(),
              let dayString = mostPopularStats.formattedMostPopularDay(),
              let timeString = mostPopularStats.formattedMostPopularTime(),
              mostPopularStats.mostPopularDayOfWeekPercentage > 0
        else {
            return []
        }

        return [StatsTwoColumnRowData.init(leftColumnName: MostPopularStats.bestDay,
                                           leftColumnData: dayString,
                                           rightColumnName: MostPopularStats.bestHour,
                                           rightColumnData: timeString)]

    }

    func createTotalFollowersRows() -> [StatsTwoColumnRowData] {
        let totalDotComFollowers = insightsStore.getDotComFollowers()?.dotComFollowersCount ?? 0
        let totalEmailFollowers = insightsStore.getEmailFollowers()?.emailFollowersCount ?? 0

        var totalPublicize = 0
        if let publicize = insightsStore.getPublicize(), !publicize.publicizeServices.isEmpty {
            totalPublicize = publicize.publicizeServices.compactMap({$0.followers}).reduce(0, +)
        }

        let totalFollowers = totalDotComFollowers + totalEmailFollowers + totalPublicize

        guard totalFollowers > 0 else {
            return []
        }

        var dataRows = [StatsTwoColumnRowData]()

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: FollowerTotals.total,
                                                   leftColumnData: totalFollowers.abbreviatedString(),
                                                   rightColumnName: FollowerTotals.wordPress,
                                                   rightColumnData: totalDotComFollowers.abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: FollowerTotals.email,
                                                   leftColumnData: totalEmailFollowers.abbreviatedString(),
                                                   rightColumnName: FollowerTotals.social,
                                                   rightColumnData: totalPublicize.abbreviatedString()))

        return dataRows
    }

    func createPublicizeRows() -> [StatsTotalRowData] {
        guard let services = insightsStore.getPublicize()?.publicizeServices else {
            return []
        }

        return services.map {
            return StatsTotalRowData(name: $0.name,
                                     data: $0.followers.abbreviatedString(),
                                     socialIconURL: $0.iconURL,
                                     statSection: .insightsPublicize)
        }
    }

    func createTodaysStatsRows() -> [StatsTwoColumnRowData] {
        guard let todaysStats = insightsStore.getTodaysStats() else {
            return []
        }

        let totalCounts = todaysStats.viewsCount +
                          todaysStats.visitorsCount +
                          todaysStats.likesCount +
                          todaysStats.commentsCount

        guard totalCounts > 0 else {
            return []
        }

        var dataRows = [StatsTwoColumnRowData]()

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: TodaysStats.viewsTitle,
                                                   leftColumnData: todaysStats.viewsCount.abbreviatedString(),
                                                   rightColumnName: TodaysStats.visitorsTitle,
                                                   rightColumnData: todaysStats.visitorsCount.abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: TodaysStats.likesTitle,
                                                   leftColumnData: todaysStats.likesCount.abbreviatedString(),
                                                   rightColumnName: TodaysStats.commentsTitle,
                                                   rightColumnData: todaysStats.commentsCount.abbreviatedString()))

        return dataRows
    }

    func createPostingActivityRow() -> PostingActivityRow {
        var monthsData = [[PostingStreakEvent]]()

        if let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date()) {
            monthsData.append(insightsStore.getMonthlyPostingActivityFor(date: twoMonthsAgo))
        }

        if let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) {
            monthsData.append(insightsStore.getMonthlyPostingActivityFor(date: oneMonthAgo))
        }

        monthsData.append(insightsStore.getMonthlyPostingActivityFor(date: Date()))

        return PostingActivityRow(monthsData: monthsData, siteStatsInsightsDelegate: siteStatsInsightsDelegate)
    }

    func createTagsAndCategoriesRows() -> [StatsTotalRowData] {
        guard let tagsAndCategories = insightsStore.getTopTagsAndCategories()?.topTagsAndCategories else {
            return []
        }

        return tagsAndCategories.map {
            let viewsCount = $0.viewsCount ?? 0

            return StatsTotalRowData(name: $0.name,
                                     data: viewsCount.abbreviatedString(),
                                     dataBarPercent: Float(viewsCount) / Float(tagsAndCategories.first?.viewsCount ?? 1),
                                     icon: StatsDataHelper.tagsAndCategoriesIconForKind($0.kind),
                                     showDisclosure: true,
                                     disclosureURL: $0.url,
                                     childRows: StatsDataHelper.childRowsForItems($0.children),
                                     statSection: .insightsTagsAndCategories)
        }
    }

    func createAnnualRows() -> [StatsTwoColumnRowData] {

        guard let annualInsights = insightsStore.getAnnualAndMostPopularTime(),
            annualInsights.annualInsightsTotalPostsCount > 0 else {
                return []
        }

        var dataRows = [StatsTwoColumnRowData]()

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AnnualSiteStats.year,
                                                   leftColumnData: String(annualInsights.annualInsightsYear),
                                                   rightColumnName: AnnualSiteStats.totalPosts,
                                                   rightColumnData: annualInsights.annualInsightsTotalPostsCount.abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AnnualSiteStats.totalComments,
                                                   leftColumnData: annualInsights.annualInsightsTotalCommentsCount.abbreviatedString(),
                                                   rightColumnName: AnnualSiteStats.commentsPerPost,
                                                   rightColumnData: Int(round(annualInsights.annualInsightsAverageCommentsCount)).abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AnnualSiteStats.totalLikes,
                                                   leftColumnData: annualInsights.annualInsightsTotalLikesCount.abbreviatedString(),
                                                   rightColumnName: AnnualSiteStats.likesPerPost,
                                                   rightColumnData: Int(round(annualInsights.annualInsightsAverageLikesCount)).abbreviatedString()))

        dataRows.append(StatsTwoColumnRowData.init(leftColumnName: AnnualSiteStats.totalWords,
                                                   leftColumnData: annualInsights.annualInsightsTotalWordsCount.abbreviatedString(),
                                                   rightColumnName: AnnualSiteStats.wordsPerPost,
                                                   rightColumnData: Int(round(annualInsights.annualInsightsAverageWordsCount)).abbreviatedString()))

        return dataRows

    }

    func createCommentsRow() -> TabbedTotalsStatsRow {
        return TabbedTotalsStatsRow(tabsData: [tabDataForCommentType(.insightsCommentsAuthors),
                                               tabDataForCommentType(.insightsCommentsPosts)],
                                    statSection: .insightsCommentsAuthors,
                                    siteStatsInsightsDelegate: siteStatsInsightsDelegate,
                                    showTotalCount: false)
    }

    func tabDataForCommentType(_ commentType: StatSection) -> TabData {
        let commentsInsight = insightsStore.getTopCommentsInsight()

        var rowItems: [StatsTotalRowData] = []

        // Ref: https://github.com/wordpress-mobile/WordPress-iOS/issues/11713
        // For now, don't show `View more` for Insights Comments.
        // To accomplish this, return only the max number of rows displayed on the Insights card,
        // as `View more` is added if the number of rows exceeds the max.

        switch commentType {
        case .insightsCommentsAuthors:
            let authors = commentsInsight?.topAuthors.prefix(StatsDataHelper.maxRowsToDisplay) ?? []
            rowItems = authors.map {
                StatsTotalRowData(name: $0.name,
                                  data: $0.commentCount.abbreviatedString(),
                                  userIconURL: $0.iconURL,
                                  showDisclosure: false,
                                  statSection: .insightsCommentsAuthors)
            }
        case .insightsCommentsPosts:
            let posts = commentsInsight?.topPosts.prefix(StatsDataHelper.maxRowsToDisplay) ?? []
            rowItems = posts.map {
                StatsTotalRowData(name: $0.name,
                                  data: $0.commentCount.abbreviatedString(),
                                  showDisclosure: true,
                                  disclosureURL: $0.postURL,
                                  statSection: .insightsCommentsPosts)
            }
        default:
            break
        }

        return TabData(tabTitle: commentType.tabTitle,
                       itemSubtitle: commentType.itemSubtitle,
                       dataSubtitle: commentType.dataSubtitle,
                       dataRows: rowItems)
    }

    func createFollowersRow() -> TabbedTotalsStatsRow {
        return TabbedTotalsStatsRow(tabsData: [tabDataForFollowerType(.insightsFollowersWordPress),
                                               tabDataForFollowerType(.insightsFollowersEmail)],
                                    statSection: .insightsFollowersWordPress,
                                    siteStatsInsightsDelegate: siteStatsInsightsDelegate,
                                    showTotalCount: true)
    }

    func tabDataForFollowerType(_ followerType: StatSection) -> TabData {
        let tabTitle = followerType.tabTitle
        var followers: [StatsFollower]?
        var totalFollowers: Int?

        switch followerType {
        case .insightsFollowersWordPress:
            followers = insightsStore.getDotComFollowers()?.topDotComFollowers
            totalFollowers = insightsStore.getDotComFollowers()?.dotComFollowersCount
        case .insightsFollowersEmail:
            followers = insightsStore.getEmailFollowers()?.topEmailFollowers
            totalFollowers = insightsStore.getEmailFollowers()?.emailFollowersCount
        default:
            break
        }

        let totalCount = String(format: followerType.totalFollowers, (totalFollowers ?? 0).abbreviatedString())

        let followersData = followers?.compactMap {
            return StatsTotalRowData(name: $0.name,
                                     data: $0.subscribedDate.relativeStringInPast(),
                                     userIconURL: $0.avatarURL,
                                     statSection: followerType)
        }

        return TabData(tabTitle: tabTitle,
                       itemSubtitle: followerType.itemSubtitle,
                       dataSubtitle: followerType.dataSubtitle,
                       totalCount: totalCount,
                       dataRows: followersData ?? [])
    }

    func createAddInsightRow() -> StatsTotalRowData {
        return StatsTotalRowData(name: StatSection.insightsAddInsight.title,
                                 data: "",
                                 icon: Style.imageForGridiconType(.plus, withTint: .darkGrey),
                                 statSection: .insightsAddInsight)
    }
}

extension SiteStatsInsightsViewModel: AsyncBlocksLoadable {
    typealias RowType = InsightType

    var currentStore: StatsInsightsStore {
        return insightsStore
    }

    public static func splitStatsSummaryTimeIntervalData(_ statsSummaryTimeIntervalData: StatsSummaryTimeIntervalData) ->
            [StatsSummaryTimeIntervalDataAsAWeek] {
        switch statsSummaryTimeIntervalData.summaryData.count {
        case let count where count == 14:
            // normal case api returns 14 rows
            let summaryData = statsSummaryTimeIntervalData.summaryData[0..<14]
            return createStatsSummaryTimeIntervalDataAsAWeeks(summaryData: Array(summaryData))
        case let count where count > 14:
            // when more than 14 rows we take the last 14 rows for most recent data
            let summaryData = statsSummaryTimeIntervalData.summaryData[count-14..<count]
            return createStatsSummaryTimeIntervalDataAsAWeeks(summaryData: Array(summaryData))
        case let count where count < 14:
            // when 0 to 14 rows presume the user could be new / doesn't have enough data.  Pad 0's to prev week
            var summaryData = statsSummaryTimeIntervalData.summaryData
            summaryData.reverse()

            guard var date = summaryData.last?.periodStartDate else {
                return []
            }

            while summaryData.count < 14 {
                if let newPeriodStartDate = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: date) {
                    date = newPeriodStartDate
                    summaryData.append(StatsSummaryData(period: .day,
                            periodStartDate: newPeriodStartDate,
                            viewsCount: 0,
                            visitorsCount: 0,
                            likesCount: 0,
                            commentsCount: 0))
                }
            }

            summaryData.reverse()
            return createStatsSummaryTimeIntervalDataAsAWeeks(summaryData: summaryData)
        default:
            return []
        }
    }

    public static func createStatsSummaryTimeIntervalDataAsAWeeks(summaryData: [StatsSummaryData]) -> [StatsSummaryTimeIntervalDataAsAWeek] {
        let half = 7
        let prevWeekData = summaryData[0 ..< half]
        let prevWeekTimeIntervalData = StatsSummaryTimeIntervalData(period: .day,
                periodEndDate: prevWeekData.last!.periodStartDate,
                summaryData: Array(prevWeekData))


        let thisWeekData = summaryData[half ..< 14]
        let thisWeekTimeIntervalData = StatsSummaryTimeIntervalData(period: .day,
                periodEndDate: thisWeekData.last!.periodStartDate,
                summaryData: Array(thisWeekData))

        return [StatsSummaryTimeIntervalDataAsAWeek.thisWeek(data: thisWeekTimeIntervalData),
                StatsSummaryTimeIntervalDataAsAWeek.prevWeek(data: prevWeekTimeIntervalData)]
    }
}
