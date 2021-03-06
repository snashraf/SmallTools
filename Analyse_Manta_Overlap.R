.libPaths("/hpc/local/CentOS7/cog/R_libs/3.2.2")
require(optparse)
#-------------------------------------------------------------------------------------------------------------------------#
options <- list(
		make_option(c("-v", "--verbose"),	action="store_true",	default=TRUE,		help="Print extra output [default]"),
		make_option(c("-q", "--quietly"),	action="store_false",	dest="verbose",		help="Print little output"),

		make_option(c("-o", "--output"),	type="chracter",	help="Output directory"),
		make_option(c("-s", "--sample"),	type="character",	help="Sample variants",	metavar="vcf"),
		make_option(c("-c", "--control"),	type="character",	help="Control variants",metavar="vcf"),

		make_option(c("-r", "--reference"),	type="character",	default="hg19",		help="Reference genome build", metavar="ref"),
		make_option("--overlap",		type="double",		default=0.85,		help="Maximum fraction to overlap reference calls [default %default]", metavar="number"),
		make_option("--passonly",		type="logical", 	default=TRUE,		help="if TRUE, ignore non PASS SVs [default %default]", metavar="logical"),
		make_option("--ignoretype",		type="logical", 	default=TRUE,		help="!TODO! if TRUE, ignore SV types [default %default] [not implemented yet]", metavar="logical")
)

parser <- OptionParser(usage = "%prog [options]", option_list=options)
arguments <- parse_args(parser, args=commandArgs(trailingOnly=TRUE),	positional_arguments=FALSE)
if (length(arguments) <= 6) {
	stop("No arguments supplied, use --help for usage options")
}
#-------------------------------------------------------------------------------------------------------------------------#

require(VariantAnnotation)
require(ggplot2)
#TODO Add SV type aware code so we can use the ignoretype flag
#-------------------------------------------------------------------------------------------------------------------------#
# FUNCTIONS

# Calculate Manta percentage non refrence
calc_pnr <- function(x) {
	if (lengths(x) <= 1) {	return(0.0)}
	y <- unlist(x)
	if (y[1]==0 && y[2]==0){return(0.0)}
	if (y[1]==0) {					return(1.0)	}
	return (y[2]/sum(y))
}

# Calculate Manta depth
calc_dp <- function(x) {
	if (lengths(x) <= 1) {return(0)}
	return(sum(unlist(x)))
}

# Process Manta file into a more usable format for filtering purposes
process_manta_vcf <- function(vcffile) {
	#print(head(rowRanges(vcffile)))
	vcfdf <- data.frame(rowRanges(trim(vcffile)))
	#print(head(vcfdf))
	
	vcfdf$end <- info(vcffile)$END
	# Identify translocation calls
	translocations <- which(is.na(info(vcffile)$END))
	
	vcfdf$end[translocations] <- vcfdf$start[translocations]+1
	vcfdf$width <- vcfdf$end-vcfdf$start
	vcfdf$type <- vcfdf$ALT
	vcfdf$type[translocations] <- "<TRA>"

	indels <- which(! vcfdf$type %in% c("<DUP:TANDEM>","<TRA>","<DEL>","<INS>","<INV>"))
	sizes <- (unlist(lapply(vcfdf$ALT, nchar)) - unlist(lapply(vcfdf$REF, nchar)))
	vcfdf$size <- sizes
	vcfdf$type[indels][sizes[indels]<0] <- "<DEL>"
	vcfdf$type[indels][sizes[indels]>0] <- "<INS>"

	# Make GRanges object
	vcfgr <- GRanges(seqnames=vcfdf$seqnames, ranges=IRanges(start=vcfdf$start, end=vcfdf$end), strand="+", type=vcfdf$type)
	rm(vcfdf)
	return(vcfgr)
}

#-------------------------------------------------------------------------------------------------------------------------#


samplevcf <- readVcf(arguments$sample, arguments$reference)
sample <- process_manta_vcf(samplevcf)

control <- process_manta_vcf(readVcf(arguments$control, arguments$reference))
#interesting_events <- which(countOverlaps(sample, control, minoverlap=1)==0)

#-------------------------------------------------------------------------------------------------------------------------#

# DETERMIN REGIONS UNIQUE TO SAMPLE
sampleunique <- setdiff(sample, control)
rm(control)

# DETERMINE IF OVERLAP OF SVs WITH UNIQUE REGIONS
hits <- findOverlaps(sample, sampleunique, minoverlap=1)
hitsdf <- data.frame(hits)
hitsdf$origwidth <- width(sample[queryHits(hits)])
# DETERMINE WHAT OVERLAPS SVs WITH UNIQUE REGIONS
overlaps <- pintersect(sample[queryHits(hits)], sampleunique[subjectHits(hits)])
hitsdf$hitwidth <- width(overlaps)
# DETERMINE PERCENTAGE OVERLAP OF SVs WITH UNIQUE REGIONS
hitsdf$perc <-round(hitsdf$hitwidth/hitsdf$origwidth,3)
uniqueness <- aggregate(perc ~ queryHits, data=hitsdf, FUN=sum)

# SELECT EVENTS THAT MATCH THE CRITERIA
selected_events <- subset(uniqueness, perc>=arguments$overlap)$queryHits

#-------------------------------------------------------------------------------------------------------------------------#
# GATHER RELEVANT DATA FOR PLOTTING
toplot <- data.frame(Type=as.character(sample$type))
toplot$PairPNR <- 	apply(data.frame(geno(samplevcf)$PR), 1, function(x) calc_pnr(x))
toplot$SplitPNR <-	apply(data.frame(geno(samplevcf)$SR), 1, function(x) calc_pnr(x))
toplot$PairDP <- 		apply(data.frame(geno(samplevcf)$PR), 1, function(x) calc_dp(x))
toplot$SplitDP <- 	apply(data.frame(geno(samplevcf)$SR), 1, function(x) calc_dp(x))
toplot$PASS <- 			rowData(samplevcf)$FILTER=="PASS"
toplot$Unique <- FALSE
toplot$Unique[selected_events] <- TRUE
toplot$DP <-	apply(toplot[,c("PairDP","SplitDP")],   1, max)
toplot$PNR <- apply(toplot[,c("PairPNR","SplitPNR")], 1, max)
#-------------------------------------------------------------------------------------------------------------------------#
# PERFORM PASS FILTERING IS REQUIRED
if (arguments$passonly) {
	selected_events <- selected_events[rowData(samplevcf)[selected_events,"FILTER"]=="PASS"]
}

cleanname <- gsub(".gz", "", arguments$sample)
cleanname <- gsub(".vcf", "", cleanname)
# WRITE RESULTS TO VCF FILE
outvcf <- paste0(arguments$ouput,"/",cleanname,"_FilteredFor_",gsub(".gz", "",arguments$control))
writeVcf(samplevcf[selected_events,], outvcf)

# PLOT THE FILTERING OVERVIEW
plotfile <- paste0("SVfiltering_",cleanname,".pdf")

pdf(file=plotfile, width=15, height=15, pointsize=12, bg="white")
	print(ggplot(toplot, aes(DP, PNR)) + geom_jitter(aes(colour=Type, alpha=Unique, shape=PASS), width=.01, height=.05))
dev.off()
#+ geom_vline(xintercept=10)

#-------------------------------------------------------------------------------------------------------------------------#
