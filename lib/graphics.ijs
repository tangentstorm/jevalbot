NB. Visualization tools for jevalbot


NB. View binary matrix using Braille (0 0 -: 2 4 | $y)
binview =: (,:~4 2) (10240 u:@+ 40283 #.@A. ,);._3 ]

NB. View binary matrix using half-block characters (0 0 -: 2 2 | $y)
blockview =: (u: 16b20 16b2584 16b2580 16b2588) {~ (,:~2 1) #.@,;._3 ]

NB. Plot an array of y values
plot =: binview@:|.@:|:@:([: I. ,.&1)@:(0.5 <.@+ 11 * (% >./)@(- <./))
