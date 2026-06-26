# Chartkick + Groupdate config for the /intelligence task-development dashboard.
#
# Groupdate buckets time series (group_by_week) using Time.zone, which Rails
# defaults to UTC here (config.time_zone is unset). Pin week_start to Monday so
# the trend buckets are deterministic across machines/CI and in tests.
Groupdate.week_start = :monday

# Library-wide Chartkick defaults: a comfortable default height and no animation
# so charts paint instantly (and the e2e canvas assertions are not racing a
# tween). Per-chart colors/options are passed in the view.
Chartkick.options = {
  height: "300px",
  library: {
    animation: false,
    maintainAspectRatio: false,
    plugins: {
      legend: {
        labels: { boxWidth: 12, boxHeight: 12, padding: 16 }
      }
    }
  }
}
