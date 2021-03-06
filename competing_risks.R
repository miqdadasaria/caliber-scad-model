# Combine estimated hazard functions together to calculate cumulative incidences 
# and competing risks
# 
# Author: Miqdad Asaria
# Date: 2014
###############################################################################
library(flexsurv)

##########################################################################################
## calculate cumulative hazards based on our underlying survival models
##########################################################################################

cumulative_gengamma_hazards = function(time, params, patients, cycle_length_days){
	mu = params[,"mu"]
	sigma = params[,"sigma"]
	Q = params[,"Q"]
	names_beta = setdiff(colnames(params), c("mu","sigma","Q","AIC","loglik"))
	betas = params[,names_beta]
	if(length(betas)>0){
		mu = mu + (patients[,names_beta] %*% betas)
	}else{
		# no coeff model run
		mu = matrix((patients[,"(Intercept)"] * mu),nrow=nrow(patients))
	}
	n = round(time/cycle_length_days)
	times = seq(0,n*cycle_length_days,cycle_length_days)
	cum_hazard = apply(mu,1,function(m){Hgengamma(times,m,sigma,Q)})
	return(cum_hazard)
}

gengamma_hazards = function(time, params, patients, cycle_length_days){
	mu = params[,"mu"]
	sigma = params[,"sigma"]
	Q = params[,"Q"]
	names_beta = setdiff(colnames(params), c("mu","sigma","Q","AIC","loglik"))
	betas = params[,names_beta]
	if(length(betas)>0){
		mu = mu + (patients[,names_beta] %*% betas)
	}else{
		# no coeff model run
		mu = matrix((patients[,"(Intercept)"] * mu),nrow=nrow(patients))
	}
	n = round(time/cycle_length_days)
	times = seq(0,n*cycle_length_days,cycle_length_days)
	hazard = apply(mu,1,function(m){hgengamma(times,m,sigma,Q)})
	return(hazard)
}

sum_subsets = function(x, cycle_length_days) {
	n = round(length(x)/cycle_length_days)
	out = array(NA,n)
	for (i in 0:(n-1)) {
		 out[i+1] = sum(x[((i*cycle_length_days)+1):((i+1)*cycle_length_days)])
	}
	return(out)
}

daily_lifetable_hazards = function(times, life_table, patients, cycle_length_days, data_years){
	cum_hazard = apply(patients,1,function(p){sum_subsets(life_table[round((p["age0"] + 70 + data_years) * 365) + times,round(p["sex"])+1],cycle_length_days)})
	if(min(times)==0){
		return(cum_hazard[times+1,])
	} else {
		return(cum_hazard[,])	
	}
}

# estimate for within data period using model and then switch to life tables used for non cvd hazard
cumulative_life_table_gengamma_hazards = function(data_years, time, gengamma_params, life_table_params, patients, cycle_length_days){
	n = round(data_years*365/cycle_length_days)
	data_time = n*cycle_length_days
	if(time<=data_time){
		data_time = round(time/cycle_length_days)*cycle_length_days
	}
	model_time = round((time-data_time)/cycle_length_days)*cycle_length_days + data_time
	haz_p1 = cumulative_gengamma_hazards(data_time,gengamma_params,patients,cycle_length_days)
	if(time>data_time){
		if(nrow(patients)>1){
			if(data_time>0){
				haz_p2 = apply(rbind(t(haz_p1[n+1,]),daily_lifetable_hazards((data_time+1):model_time, life_table_params, patients, cycle_length_days, data_years)),2,cumsum)
				haz = rbind(haz_p1[-(n+1),],haz_p2)
			} else {
				haz_p2 = apply(daily_lifetable_hazards((data_time):model_time, life_table_params, patients, cycle_length_days, data_years),2,cumsum)
				haz = haz_p2
			}
		} else {
			if(data_time>0){
				haz_p2 = matrix(cumsum(c(haz_p1[n+1,],daily_lifetable_hazards((data_time+1):model_time, life_table_params, patients, cycle_length_days, data_years))),ncol=1)
				haz_p1 = matrix(haz_p1[-(n+1),],ncol=1)
				haz = rbind(haz_p1,haz_p2)	
			} else {
				haz_p2 = matrix(cumsum(daily_lifetable_hazards((data_time):model_time, life_table_params, patients, cycle_length_days, data_years)),ncol=1)
				haz = haz_p2	
			}
		}
	}else{
		haz = haz_p1
	}
	return(haz)
}

##########################################################################################
## calculate overall survival from all our competing risks
##########################################################################################

# calculate overall survival i.e. probability that no first event has occured over time
calculate_overall_survival = function(time, mi, stroke_i, stroke_h, fatal_cvd, fatal_non_cvd, patients, cycle_length_days){
	n = round(time/cycle_length_days)
	times = seq(0,n*cycle_length_days,cycle_length_days)
	survival = array(NA,c(n+1,2,nrow(patients)),list(times,c("time","overall_survival"),1:nrow(patients)))
	survival[,"time",] = times
	# S(t) = exp(-(H[mi](t)+H[stroke](t)+...))
	survival[,"overall_survival",] = exp(-(mi + stroke_i + stroke_h + fatal_cvd + fatal_non_cvd))
	return(survival)
}

# calculate subsequent event overall survival
calculate_se_survival = function(time, cvd_mort_haz, non_cvd_mort_haz, patients, cycle_length_days){
	n = round(time/cycle_length_days)
	times = seq(0,n*cycle_length_days,cycle_length_days)
	survival = array(NA,c(n+1,2,nrow(patients)),list(times,c("time","overall_survival"),1:nrow(patients)))
	survival[,"time",] = times
	survival[,"overall_survival",] = exp(-(cvd_mort_haz + non_cvd_mort_haz))
	return(survival)
}

##########################################################################################
## calculate incidence functions and cumulative incidence functions (CIFs) by cause
##########################################################################################

# calculate incidence of event at each point in time given overall survival and hazards 
calculate_incidence = function(time, survival, cum_hazards, patients, cycle_length_days){
	n = round(time/cycle_length_days)
	times = seq(cycle_length_days,n*cycle_length_days,cycle_length_days)
	incidence = array(NA,c(n,2,nrow(patients)),list(times,c("time","incidence"),1:nrow(patients)))
	incidence[,"time",] = times
	# [H(t)-H(t-1)]*S(t-1)
	incidence[,"incidence",] = (cum_hazards[2:(n+1),] - cum_hazards[1:n,]) * survival[1:n,"overall_survival",]
	return(incidence)
}

# calculate cumulative incidence function given cumulative hazards
# if data for multiple patients is provided mean CIF is calculated
calculate_cumulative_incidence = function(time, survival, cum_hazards, patients, cycle_length_days){
	incidence = calculate_incidence(time, survival, cum_hazards, patients, cycle_length_days)
	if(dim(incidence)[3]==1){
		# if representative patient
		ci = cumsum(incidence[,2,])
	}else{
		# if multiple patients
		ci_pat = apply(incidence[,2,],2,cumsum)
		ci = apply(ci_pat,1,mean) 
	}
	n = round(time/cycle_length_days)
	times = seq(cycle_length_days,n*cycle_length_days,cycle_length_days)
	ci = cbind(times,ci)
	colnames(ci) = c("time","cumulative_incidence")
	return(ci)
}

########################################################################
## calculate the competing risks model and return cumulative incidences 
########################################################################

# given estimated survival parameters and a patient this function calculates the cumulative incidence functions 
# for all 11 of our risk equations for the covariate profile reflected by the given patient
# treatment_HRs and scenarios can be used to model treatment alternatives
calculate_competing_risks_model = function(survival_params, patients, prediction_years, observed_data_years, cycle_length_days, treatment_HR, scenario){
	model_time = round(prediction_years*365)
	# calculate cumulative hazards
	fe_mi_haz = cumulative_gengamma_hazards(model_time,survival_params[["fe_mi_params"]],patients,cycle_length_days)
	fe_stroke_i_haz = cumulative_gengamma_hazards(model_time,survival_params[["fe_stroke_i_params"]],patients,cycle_length_days)
	fe_stroke_h_haz = cumulative_gengamma_hazards(model_time,survival_params[["fe_stroke_h_params"]],patients,cycle_length_days)
	fe_fatal_cvd_haz = cumulative_gengamma_hazards(model_time,survival_params[["fe_fatal_cvd_params"]],patients,cycle_length_days)
	fe_fatal_non_cvd_haz = cumulative_life_table_gengamma_hazards(observed_data_years,model_time,survival_params[["fe_fatal_non_cvd_params"]],survival_params[["life_table_non_cvd_daily_hazards"]],patients,cycle_length_days)
	fatal_non_cvd_post_mi_haz = cumulative_life_table_gengamma_hazards(observed_data_years,model_time,survival_params[["fatal_non_cvd_post_mi_params"]],survival_params[["life_table_non_cvd_daily_hazards"]],patients,cycle_length_days)
	fatal_non_cvd_post_stroke_i_haz = cumulative_life_table_gengamma_hazards(observed_data_years,model_time,survival_params[["fatal_non_cvd_post_stroke_i_params"]],survival_params[["life_table_non_cvd_daily_hazards"]],patients,cycle_length_days)
	fatal_non_cvd_post_stroke_h_haz = cumulative_life_table_gengamma_hazards(observed_data_years,model_time,survival_params[["fatal_non_cvd_post_stroke_h_params"]],survival_params[["life_table_non_cvd_daily_hazards"]],patients,cycle_length_days)
	fatal_cvd_post_mi_haz = cumulative_gengamma_hazards(model_time,survival_params[["fatal_cvd_post_mi_params"]],patients,cycle_length_days)
	fatal_cvd_post_stroke_i_haz = cumulative_gengamma_hazards(model_time,survival_params[["fatal_cvd_post_stroke_i_params"]],patients,cycle_length_days)
	fatal_cvd_post_stroke_h_haz = cumulative_gengamma_hazards(model_time,survival_params[["fatal_cvd_post_stroke_h_params"]],patients,cycle_length_days)	
	
	# reduce the first CVD event hazard rates except stroke h
	if(scenario == "fe_cvd" | scenario == "all_cvd") {
		fe_mi_haz = fe_mi_haz*treatment_HR
		fe_stroke_i_haz = fe_stroke_i_haz*treatment_HR
		fe_fatal_cvd_haz = fe_fatal_cvd_haz*treatment_HR
	}
	
	# reduce the post event CVD mortality hazard rates
	if(scenario == "all_cvd"){
		fatal_cvd_post_mi_haz = fatal_cvd_post_mi_haz * treatment_HR 
		fatal_cvd_post_stroke_i_haz = fatal_cvd_post_stroke_i_haz * treatment_HR
		fatal_cvd_post_stroke_h_haz = fatal_non_cvd_post_stroke_h_haz * treatment_HR
	} 

	## calculate cumulative incidences for first events
	# overall survival
	overall_survival = calculate_overall_survival(model_time, fe_mi_haz, fe_stroke_i_haz, fe_stroke_h_haz, fe_fatal_cvd_haz, fe_fatal_non_cvd_haz, patients, cycle_length_days)
	# non fatal MI
	fe_mi_ci = calculate_cumulative_incidence(model_time, overall_survival, fe_mi_haz, patients, cycle_length_days)
	# non fatal stroke_i
	fe_stroke_i_ci = calculate_cumulative_incidence(model_time, overall_survival, fe_stroke_i_haz, patients, cycle_length_days)
	# non fatal stroke_h
	fe_stroke_h_ci = calculate_cumulative_incidence(model_time, overall_survival, fe_stroke_h_haz, patients, cycle_length_days)
	# fatal cvd
	fe_fatal_cvd_ci = calculate_cumulative_incidence(model_time, overall_survival, fe_fatal_cvd_haz, patients, cycle_length_days)
	# fatal non cvd
	fe_fatal_non_cvd_ci = calculate_cumulative_incidence(model_time, overall_survival, fe_fatal_non_cvd_haz, patients, cycle_length_days)
	
	## calculate incidences for subsequent events
	# post MI
	post_mi_survival = calculate_se_survival(model_time,fatal_cvd_post_mi_haz,fatal_non_cvd_post_mi_haz,patients,cycle_length_days)
	fatal_cvd_post_mi_ci = calculate_cumulative_incidence(model_time,post_mi_survival,fatal_cvd_post_mi_haz,patients,cycle_length_days)
	fatal_non_cvd_post_mi_ci = calculate_cumulative_incidence(model_time,post_mi_survival,fatal_non_cvd_post_mi_haz,patients,cycle_length_days)
	# post stroke I
	post_stroke_i_survival = calculate_se_survival(model_time,fatal_cvd_post_stroke_i_haz,fatal_non_cvd_post_stroke_i_haz,patients,cycle_length_days)
	fatal_cvd_post_stroke_i_ci = calculate_cumulative_incidence(model_time,post_stroke_i_survival,fatal_cvd_post_stroke_i_haz,patients,cycle_length_days)
	fatal_non_cvd_post_stroke_i_ci = calculate_cumulative_incidence(model_time,post_stroke_i_survival,fatal_non_cvd_post_stroke_i_haz,patients,cycle_length_days)
	# post stroke H
	post_stroke_h_survival = calculate_se_survival(model_time,fatal_cvd_post_stroke_h_haz,fatal_non_cvd_post_stroke_h_haz,patients,cycle_length_days)
	fatal_cvd_post_stroke_h_ci = calculate_cumulative_incidence(model_time,post_stroke_h_survival,fatal_cvd_post_stroke_h_haz,patients,cycle_length_days)
	fatal_non_cvd_post_stroke_h_ci = calculate_cumulative_incidence(model_time,post_stroke_h_survival,fatal_non_cvd_post_stroke_h_haz,patients,cycle_length_days)

	# combine in a list to return all 11 CIFs
	cis = list(fe_mi_ci,fe_stroke_i_ci,fe_stroke_h_ci,fe_fatal_cvd_ci,fe_fatal_non_cvd_ci,fatal_cvd_post_mi_ci,fatal_non_cvd_post_mi_ci,fatal_cvd_post_stroke_i_ci,fatal_non_cvd_post_stroke_i_ci,fatal_cvd_post_stroke_h_ci,fatal_non_cvd_post_stroke_h_ci)
	names(cis) = c("fe_mi","fe_stroke_i","fe_stroke_h","fe_fatal_cvd","fe_fatal_non_cvd","post_mi_fatal_cvd","post_mi_fatal_non_cvd","post_stroke_i_fatal_cvd","post_stroke_i_fatal_non_cvd","post_stroke_h_fatal_cvd","post_stroke_h_fatal_non_cvd")
	return(cis)
}