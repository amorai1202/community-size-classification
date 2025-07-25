# ========================================================================================================================
# Community Size Classification – Canadian Example
# 
# This script demonstrates how to classify geographic grid cells into community size categories 
# based on local population density. 
# The approach uses 10km × 10km gridded population data and applies a neighborhood-based method to 
# compute local density, which is then used to assign each cell a category 
# (e.g., Metropolis, Large urban community, Small urban community, Rural town, Rural village).
#
# Input data:
# - 2021 Census subdivision boundaries (CSDs)
# - 2016 10km population grid for Canada
# - Crosswalk between CSDs and Economic Regions (ERs)
#
# Key outputs:
# - A spatial dataframe (`can_classify`) with each grid cell labeled as a specific community type
# - Visualizations of the classification across sample economic regions (Lower Mainland–Southwest, BC; Toronto, Ont.)
#
# This example is designed to be adapted to other geographies or input datasets that follow a similar grid + boundary structure.
# ========================================================================================================================

### Load packages ----
library(sf)
library(spdep)
library(tidyverse)

### Load data ----

# 2021 Census geographic boundaries - census subdivisions
csd_boundary <- read_sf("data/csd_boundary_2021/lcsd000a21a_e.shp")
# 10km x 10km population grid - 2016 Census population
raw_grid <- read_sf("data/griddedPopulationCanada10km_2016_shp")
# Crosswalk between census subdivisions (CSDs) and economic regions (ERs)
crosswalk <- read_csv("data/crosswalk_csd_er.csv", 
                      col_types = cols(CSDUID = col_character(), ERUID = col_character()))

### Classification for Canada ----

# Filter out ID 0 grids (no data, e.g., body of water)
grid_df <- raw_grid |> filter(BIOMASS_FR != 0)

# Create neighbors list
nb <- poly2nb(grid_df, queen=TRUE) # queen=TRUE means cells sharing just a corner are considered neighbors
# Convert nb into a spatial weights list
lw <- nb2listw(nb, style="W", zero.policy=TRUE)

# Total population/area of neighboring cells
neighbors_pop <- lag.listw(lw, grid_df$TOT_POP2A, zero.policy=TRUE) 
neighbors_area <- lag.listw(lw, grid_df$TOT_LND_AR, zero.policy=TRUE)

# Add own population and area to the neighbors' totals
grid_df$pop_local <- grid_df$TOT_POP2A + neighbors_pop
grid_df$area_local <- grid_df$TOT_LND_AR + neighbors_area

# Calculate local population density
grid_df$local_pop_density <- grid_df$pop_local / grid_df$area_local

# Perform spatial intersection to join CSDs with ERs
grid_transform <- st_transform(grid_df, st_crs(csd_boundary))
grid_join <- st_intersection(grid_transform, csd_boundary) # Note: takes a while to run

# For each grid, keep the CSD with the largest overlapping area and add ER information
grid_linking <- grid_join |> 
  # Extract the area of the overlap
  mutate(overlap_area = st_area(geometry)) |> 
  group_by(BIOMASS_FR) |> 
  # Select the CSD with most overlap
  slice_max(overlap_area, with_ties = FALSE) |>  
  ungroup() |>
  # Join ERs
  left_join(crosswalk |> select(CSDUID, ERUID, ERNAME, PRNAME), by = "CSDUID") 

# Classify grid cells based on local density
grid_classify <- grid_linking |>
  mutate(Category = factor(
    case_when(
      local_pop_density >= 1000 ~ "Metropolis",
      round(local_pop_density,-2) >= 500  ~ "Large urban community",
      local_pop_density >= 100  ~ "Small urban community",
      local_pop_density >= 10   ~ "Rural town",
      local_pop_density < 10    ~ "Rural village",
      TRUE                      ~ "Unknown"
    ),
    levels = c("Metropolis", "Large urban community", "Small urban community", 
               "Rural town", "Rural village", "Unknown")
  )) 

# Manually reclassify edge cases to better reflect known realities
grid_classify_edit <- grid_classify |> 
  mutate(Category = case_when(
    # Southeast rural grids - close to Winnipeg
    ERUID == 4610 & Category %in% c("Large urban community", "Small urban community") ~ "Rural town",
    # Interlake rural grids - close to Winnipeg
    ERUID == 4660 & Category %in% c("Large urban community", "Small urban community") ~ "Rural town",
    # Lethbridge from small to large community
    ERUID == 4810 & CSDNAME == "Lethbridge" ~ "Large urban community",
    # Red Deer from small to large community
    ERUID == 4850 & CSDNAME == "Red Deer" ~ "Large urban community",
    # Headingley from large community to village
    ERUID == 4650 & CSDNAME == "Headingley" ~ "Rural village",
    # St. Catharines from small to large community
    ERUID == 3550 & CSDNAME == "St. Catharines" ~ "Large urban community",
    # All other grids - keep original category
    TRUE ~ Category
  ))

# Final Canada classification
can_classify <- grid_classify_edit |> 
  select(BIOMASS_FR, PRNAME, ERNAME, CSDNAME, TOT_POP2A, pop_local, local_pop_density, Category, geometry)

# OPTIONAL: Save classification
# write_sf(can_classify, "data/can_classify_2021.shp")

### Visualize classification ----

# Lower Mainland example
lower_mainland <- can_classify |> filter(ERNAME == "Lower Mainland--Southwest") # Lower Mainland example
lower_mainland$Category <- factor(
  lower_mainland$Category,
  levels = c("Metropolis",
             "Large urban community",
             "Small urban community",
             "Rural town",
             "Rural village",
             "Unknown")
)
vancouver <- can_classify |> filter(CSDNAME == "Vancouver")  # Vancouver CSD

# Plot all grids in Lower Mainland
ggplot() +
  geom_sf(data = lower_mainland, fill = "white", color = "black") +
  # Color Vancouver CSD
  geom_sf(data = csd_boundary |> filter(CSDNAME %in% c("Vancouver")), fill = "blue", color = "black") +
  # Color each grid by population density
  geom_sf(data = lower_mainland, aes(fill = local_pop_density), alpha = 0.3) +
  scale_fill_gradient(low = "white", high = "red", name = "Local population\ndensity (people/km²)") +
  theme_minimal()

# Plot all grids in Lower Mainland by category
ggplot(data = lower_mainland) +
  geom_sf(aes(fill = Category), color = "black") +  
  scale_fill_manual(values = c(
    "Metropolis" = "red",           
    "Large urban community" = "orange",        
    "Small urban community" = "yellow",       
    "Rural town" = "lightgreen",         
    "Rural village" = "lightblue",       
    "Unknown" = "gray"                    
  )) +
  theme_minimal()

# Toronto example
toronto <- can_classify |> filter(ERNAME == "Toronto") # Lower Mainland example
toronto$Category <- factor(
  toronto$Category,
  levels = c("Metropolis",
             "Large urban community",
             "Small urban community",
             "Rural town",
             "Rural village",
             "Unknown")
)

# Plot all grids in Toronto by category
ggplot(data = toronto) +
  geom_sf(aes(fill = Category), color = "black") +  
  scale_fill_manual(values = c(
    "Metropolis" = "red",           
    "Large urban community" = "orange",        
    "Small urban community" = "yellow",       
    "Rural town" = "lightgreen",         
    "Rural village" = "lightblue",       
    "Unknown" = "gray"                    
  )) +
  theme_minimal()


